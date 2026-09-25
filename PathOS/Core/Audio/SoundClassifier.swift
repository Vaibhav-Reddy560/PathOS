import AVFoundation
import Observation
import SoundAnalysis

nonisolated enum SoundScene: String, Sendable {
    case quiet
    case moderate
    case noisy
    case unknown

    var label: String {
        switch self {
        case .quiet: "Quiet space"
        case .moderate: "Normal ambience"
        case .noisy: "Noisy surroundings"
        case .unknown: "Not listening"
        }
    }

    var symbol: String {
        switch self {
        case .quiet: "speaker.wave.1.fill"
        case .moderate: "speaker.wave.2.fill"
        case .noisy: "speaker.wave.3.fill"
        case .unknown: "speaker.slash.fill"
        }
    }
}

nonisolated struct SoundUpdate: Sendable {
    var levelDB: Double?
    var label: String?
    var confidence: Double?
}

nonisolated enum SoundSceneRules {
    static let quietBelowDB = -50.0
    static let noisyAboveDB = -32.0
    static let noisyKeywords = [
        "train", "subway", "metro", "rail", "bus", "traffic", "vehicle", "engine", "motorcycle",
        "truck", "horn", "siren", "crowd", "cheering", "applause", "aircraft", "music", "construction",
    ]

    static func scene(levelDB: Double?, label: String?, confidence: Double?) -> SoundScene {
        guard let levelDB else { return .unknown }
        let loudLabel = label.map { identifier in
            noisyKeywords.contains { identifier.lowercased().contains($0) }
        } ?? false
        if levelDB >= noisyAboveDB || (loudLabel && (confidence ?? 0) >= 0.6 && levelDB >= -45) {
            return .noisy
        }
        if levelDB <= quietBelowDB {
            return .quiet
        }
        return .moderate
    }

    /// Whether the phone's microphone can be used while you're listening to something.
    ///
    /// With headphones or earbuds on, what you're hearing goes to them, and the phone's own
    /// microphone can listen alongside without touching it. Through the phone's speaker, taking
    /// the microphone would interrupt what's playing, and it would only hear your own music, so
    /// it stands aside.
    static func mayListen(otherAudioPlaying: Bool, headphonesOn: Bool) -> Bool {
        !otherAudioPlaying || headphonesOn
    }
}

/// Classifies the ambient sound scene. Runs only while the app or a PathOS session is active.
///
/// It never interrupts music or a video you're playing. With headphones or earbuds on, it listens
/// through the phone's own microphone while they keep playing; through the phone's speaker, it
/// doesn't listen while anything else plays, and lets go the moment something starts or the
/// headphones come off. What it last heard is kept for the alerts that need it.
@Observable
final class SoundClassifier {
    private(set) var scene: SoundScene = .unknown
    private(set) var topLabel: String?
    private(set) var levelDB: Double?
    private(set) var isRunning = false
    private(set) var lastError: String?
    /// Standing aside for something playing through the phone's speaker.
    private(set) var isPausedForOtherAudio = false
    /// Called when it may be able to listen again: headphones went on, or an interruption ended.
    @ObservationIgnored var onMayResume: (() -> Void)?

    @ObservationIgnored private var pipeline: SoundPipeline?
    @ObservationIgnored private var consumeTask: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        // Something started playing. On the speaker, stand aside; in headphones, carry on.
        observers.append(center.addObserver(forName: AVAudioSession.silenceSecondaryAudioHintNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.standAsideIfNeeded() }
        })
        // Headphones off with something playing: that's the speaker now. Headphones on: try again.
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            MainActor.assumeIsolated {
                guard let self, let raw, let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
                switch reason {
                case .oldDeviceUnavailable: self.standAsideIfNeeded()
                case .newDeviceAvailable: self.onMayResume?()
                default: break
                }
            }
        })
        // A call or another app took the audio: the engine has stopped, so let go properly, and
        // come back once it's over.
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            MainActor.assumeIsolated {
                guard let self, let raw, let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
                if type == .began, self.isRunning {
                    self.stop()
                } else if type == .ended {
                    self.onMayResume?()
                }
            }
        })
    }

    /// Something else is playing: music, a podcast, a video.
    static var isOtherAudioPlaying: Bool {
        let session = AVAudioSession.sharedInstance()
        return session.isOtherAudioPlaying || session.secondaryAudioShouldBeSilencedHint
    }

    /// Wired headphones, AirPods or any Bluetooth earphones: what's playing goes to them.
    static var areHeadphonesOn: Bool {
        let headphones: Set<AVAudioSession.Port> = [.headphones, .bluetoothA2DP, .bluetoothLE, .bluetoothHFP]
        return AVAudioSession.sharedInstance().currentRoute.outputs.contains { headphones.contains($0.portType) }
    }

    private static var mayListenNow: Bool {
        SoundSceneRules.mayListen(otherAudioPlaying: isOtherAudioPlaying, headphonesOn: areHeadphonesOn)
    }

    private func standAsideIfNeeded() {
        guard isRunning, !Self.mayListenNow else { return }
        stop()
        isPausedForOtherAudio = true
    }

    func start() async {
        guard !isRunning else { return }
        guard Self.mayListenNow else {
            isPausedForOtherAudio = true
            return
        }
        isPausedForOtherAudio = false
        guard await AVAudioApplication.requestRecordPermission() else {
            lastError = "Microphone access is off."
            return
        }
        // Checked again: the permission prompt can take a while to answer.
        guard Self.mayListenNow else {
            isPausedForOtherAudio = true
            return
        }

        let (stream, continuation) = AsyncStream<SoundUpdate>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let pipeline = SoundPipeline(continuation: continuation)
        do {
            try pipeline.start()
        } catch {
            lastError = error.localizedDescription
            return
        }
        self.pipeline = pipeline
        isRunning = true
        lastError = nil

        consumeTask = Task { [weak self] in
            for await update in stream {
                self?.apply(update)
            }
        }
    }

    func stop() {
        pipeline?.stop()
        pipeline = nil
        consumeTask?.cancel()
        consumeTask = nil
        isRunning = false
        if scene != .unknown { scene = .unknown }
    }

    private func apply(_ update: SoundUpdate) {
        if let level = update.levelDB { levelDB = level }
        if let label = update.label { topLabel = label.replacingOccurrences(of: "_", with: " ") }
        scene = SoundSceneRules.scene(levelDB: levelDB, label: update.label ?? topLabel, confidence: update.confidence)
        remember(scene)
    }

    /// Kept on disk with its time, because the microphone stops when PathOS closes and an alert
    /// fires long after: the last thing heard is the only clue to what it's up against.
    private func remember(_ scene: SoundScene) {
        guard scene != .unknown else { return }
        UserDefaults.standard.set(scene.rawValue, forKey: Self.lastSceneKey)
        UserDefaults.standard.set(Date(), forKey: Self.lastSceneAtKey)
    }

    static let lastSceneKey = "pathos.lastScene"
    static let lastSceneAtKey = "pathos.lastSceneAt"

    /// What PathOS last heard, and when.
    static var lastHeard: (scene: SoundScene, at: Date)? {
        guard let raw = UserDefaults.standard.string(forKey: lastSceneKey),
              let scene = SoundScene(rawValue: raw),
              let at = UserDefaults.standard.object(forKey: lastSceneAtKey) as? Date else { return nil }
        return (scene, at)
    }
}

/// Audio-thread side. Kept out of the main actor so the tap never trips isolation checks.
nonisolated private final class SoundPipeline: NSObject, SNResultsObserving, @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let analysisQueue = DispatchQueue(label: "com.vaibhavreddy.pathos.sound")
    private let continuation: AsyncStream<SoundUpdate>.Continuation
    private var analyzer: SNAudioStreamAnalyzer?
    private var lastLevelDB: Double?

    init(continuation: AsyncStream<SoundUpdate>.Continuation) {
        self.continuation = continuation
    }

    func start() throws {
        let session = AVAudioSession.sharedInstance()
        // Mixable, so it never stops anything playing. `.allowBluetoothA2DP` keeps earbuds on
        // their full-quality music connection, where the phone's audio would otherwise be moved
        // off them; hands-free Bluetooth (`.allowBluetooth`) is left out on purpose, since it
        // would turn AirPods into a phone call's headset.
        try session.setCategory(.playAndRecord, mode: .measurement,
                                options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP])
        try session.setActive(true)
        // The phone's own microphone: what's around you, not what's in your ears.
        if let builtIn = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
            try? session.setPreferredInput(builtIn)
        }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        let analyzer = SNAudioStreamAnalyzer(format: format)
        let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
        request.windowDuration = CMTime(seconds: 1.5, preferredTimescale: 48_000)
        request.overlapFactor = 0.5
        try analyzer.add(request, withObserver: self)
        self.analyzer = analyzer

        input.installTap(onBus: 0, bufferSize: 8192, format: format) { @Sendable [weak self] buffer, time in
            nonisolated(unsafe) let buffer = buffer
            self?.analysisQueue.async {
                guard let self else { return }
                self.lastLevelDB = Self.decibels(of: buffer)
                analyzer.analyze(buffer, atAudioFramePosition: time.sampleTime)
            }
        }

        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        analysisQueue.sync {
            analyzer?.completeAnalysis()
        }
        continuation.finish()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let classification = result as? SNClassificationResult,
              let top = classification.classifications.first else { return }
        continuation.yield(SoundUpdate(levelDB: lastLevelDB, label: top.identifier, confidence: top.confidence))
    }

    func request(_ request: SNRequest, didFailWithError error: Error) {
        continuation.yield(SoundUpdate(levelDB: lastLevelDB, label: nil, confidence: nil))
    }

    func requestDidComplete(_ request: SNRequest) {}

    static func decibels(of buffer: AVAudioPCMBuffer) -> Double? {
        guard let samples = buffer.floatChannelData?[0] else { return nil }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return nil }
        var sumOfSquares: Float = 0
        for index in 0..<count {
            sumOfSquares += samples[index] * samples[index]
        }
        let rms = sqrt(sumOfSquares / Float(count))
        return Double(20 * log10(max(rms, 1e-7)))
    }
}
