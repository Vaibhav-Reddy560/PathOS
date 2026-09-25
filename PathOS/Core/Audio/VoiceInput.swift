import AVFoundation
import Observation
import Speech

/// Push-to-talk speech recognition that stops itself after a short silence.
@Observable
final class VoiceInput {
    private(set) var transcript = ""
    private(set) var isListening = false
    private(set) var lastError: String?

    @ObservationIgnored private var session: SpeechSession?

    static let silenceTimeout: Duration = .seconds(1.6)

    /// Listens until the speaker pauses (or `maxDuration`) and returns the final transcript.
    func listen(maxDuration: Duration = .seconds(15)) async -> String? {
        guard !isListening else { return nil }
        guard await Self.speechAuthorization() == .authorized else {
            lastError = "Speech recognition is off. Enable it in Settings → PathOS."
            return nil
        }
        guard await AVAudioApplication.requestRecordPermission() else {
            lastError = "Microphone access is off. Enable it in Settings → PathOS."
            return nil
        }

        let (stream, continuation) = AsyncStream<SpeechEvent>.makeStream()
        guard let session = SpeechSession(continuation: continuation) else {
            lastError = "Speech recognition isn't available right now."
            return nil
        }
        do {
            try session.start()
        } catch {
            lastError = error.localizedDescription
            return nil
        }

        self.session = session
        transcript = ""
        lastError = nil
        isListening = true

        let deadline = Task {
            try? await Task.sleep(for: maxDuration)
            if !Task.isCancelled { session.stop() }
        }
        var silenceTimer: Task<Void, Never>?
        var result: String?

        for await event in stream {
            switch event {
            case .partial(let text):
                transcript = text
                silenceTimer?.cancel()
                silenceTimer = Task {
                    try? await Task.sleep(for: Self.silenceTimeout)
                    if !Task.isCancelled { session.stop() }
                }
            case .final(let text):
                transcript = text
                result = text
            case .failed(let message):
                if transcript.isEmpty {
                    lastError = message
                } else {
                    result = transcript
                }
            }
        }

        deadline.cancel()
        silenceTimer?.cancel()
        self.session = nil
        isListening = false
        let trimmed = result?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    func stopListening() {
        session?.stop()
    }

    func cancel() {
        session?.cancel()
    }

    nonisolated private static func speechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { @Sendable status in
                continuation.resume(returning: status)
            }
        }
    }
}

/// Speaks answers and directions aloud.
///
/// Music or a video playing in another app pauses while it speaks and carries on as soon as it's
/// done, the way a navigation app's voice does. It used to duck the music instead and never hand
/// the audio back, which left the music quiet, or stopped, until PathOS happened to let go.
@Observable
final class SpeechOutput: NSObject {
    private(set) var isSpeaking = false
    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String) {
        let session = AVAudioSession.sharedInstance()
        // Not mixable, so what's playing pauses rather than talking over the directions;
        // `.playback` keeps it working with the screen off, which is when directions matter.
        try? session.setCategory(.playback, mode: .voicePrompt, options: [])
        try? session.setActive(true)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-IN") ?? AVSpeechSynthesisVoice(language: "en-US")
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = true
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    /// Finished: the audio goes back, and whatever was playing picks up where it paused.
    fileprivate func handBack() {
        guard !synthesizer.isSpeaking, isSpeaking else { return }
        isSpeaking = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

extension SpeechOutput: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.handBack() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.handBack() }
    }
}

nonisolated enum SpeechEvent: Sendable {
    case partial(String)
    case final(String)
    case failed(String)
}

nonisolated private final class SpeechSession: @unchecked Sendable {
    private let recognizer: SFSpeechRecognizer
    private let engine = AVAudioEngine()
    private let request = SFSpeechAudioBufferRecognitionRequest()
    private let continuation: AsyncStream<SpeechEvent>.Continuation
    private var task: SFSpeechRecognitionTask?
    private let lock = NSLock()
    private var audioStopped = false

    init?(continuation: AsyncStream<SpeechEvent>.Continuation) {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-IN")) ?? SFSpeechRecognizer(),
              recognizer.isAvailable else { return nil }
        self.recognizer = recognizer
        self.continuation = continuation
    }

    func start() throws {
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker])
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { @Sendable [weak self] buffer, _ in
            self?.request.append(buffer)
        }

        task = recognizer.recognitionTask(with: request) { @Sendable [weak self] result, error in
            guard let self else { return }
            if let result {
                let text = result.bestTranscription.formattedString
                if result.isFinal {
                    self.continuation.yield(.final(text))
                    self.finish()
                } else {
                    self.continuation.yield(.partial(text))
                }
            } else if let error {
                self.continuation.yield(.failed(error.localizedDescription))
                self.finish()
            }
        }

        engine.prepare()
        try engine.start()
    }

    /// Stops capturing audio; the final transcript follows shortly.
    func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard !audioStopped else { return }
        audioStopped = true
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request.endAudio()
    }

    func cancel() {
        task?.cancel()
        finish()
    }

    private func finish() {
        stop()
        continuation.finish()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
