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
}

/// Classifies the ambient sound scene. Runs only while the app or a PathOS session is active.
@Observable
final class SoundClassifier {
    private(set) var scene: SoundScene = .unknown
    private(set) var topLabel: String?
    private(set) var levelDB: Double?
    private(set) var isRunning = false
    private(set) var lastError: String?

    @ObservationIgnored private var pipeline: SoundPipeline?
    @ObservationIgnored private var consumeTask: Task<Void, Never>?

    func start() async {
        guard !isRunning else { return }
        guard await AVAudioApplication.requestRecordPermission() else {
            lastError = "Microphone access is off."
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
    }

    private func apply(_ update: SoundUpdate) {
        if let level = update.levelDB { levelDB = level }
        if let label = update.label { topLabel = label.replacingOccurrences(of: "_", with: " ") }
        scene = SoundSceneRules.scene(levelDB: levelDB, label: update.label ?? topLabel, confidence: update.confidence)
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
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.mixWithOthers, .defaultToSpeaker])
        try session.setActive(true)

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
