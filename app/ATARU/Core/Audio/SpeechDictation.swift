import AVFoundation
import Foundation
import Speech

/// Turns held-button speech into text, on the device.
///
/// **`requiresOnDeviceRecognition` is set to true and that is not optional.**
/// Without it `SFSpeechRecognizer` streams captured audio to Apple's servers
/// for transcription — which would mean questions about a private vault
/// leaving the phone before ATARU ever saw them, defeating the entire point of
/// running the assistant at home. If on-device recognition is unavailable for
/// the current locale, dictation reports `unavailable` and the UI offers
/// typing instead. It never silently falls back to the network path.
@MainActor
final class SpeechDictation: NSObject, ObservableObject {

    enum Failure: LocalizedError, Equatable {
        case permissionDenied
        case unavailable
        case noSpeechDetected
        case engine(String)

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return "ATARU needs microphone and speech access to hear your question. Enable them in Settings."
            case .unavailable:
                return "On-device dictation isn't available for this language, and ATARU won't send your audio to Apple to transcribe it. Type your question instead."
            case .noSpeechDetected:
                return "I didn't hear anything."
            case .engine(let detail):
                return "Couldn't start the microphone (\(detail))."
            }
        }
    }

    /// Live transcription, updated while the user speaks.
    @Published private(set) var transcript: String = ""
    @Published private(set) var isRecording = false
    /// Rough input level, 0...1, for the orb.
    @Published private(set) var level: Double = 0

    private let engine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    /// Asks for microphone and speech permission.
    ///
    /// Static so onboarding can ask before any dictation object exists; the
    /// system remembers the answer, so later per-session calls are no-ops.
    static func requestAuthorization() async -> Bool {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard speech == .authorized else { return false }
        return await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
        }
    }

    /// Asks for microphone and speech permission.
    func requestAuthorization() async -> Bool {
        await Self.requestAuthorization()
    }

    /// Begins capturing. Throws rather than failing quietly, because a
    /// dictation button that appears to work but records nothing is worse than
    /// one that says why it can't.
    func start() throws {
        guard !isRecording else { return }

        let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer()
        guard let recognizer, recognizer.isAvailable else { throw Failure.unavailable }
        guard recognizer.supportsOnDeviceRecognition else { throw Failure.unavailable }
        self.recognizer = recognizer

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true   // see the type's doc comment
        self.request = request

        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playAndRecord, mode: .spokenAudio,
                                         options: [.duckOthers, .defaultToSpeaker])
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            throw Failure.engine(error.localizedDescription)
        }

        transcript = ""
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak self] buffer, _ in
            request.append(buffer)
            let peak = Self.peakLevel(of: buffer)
            Task { @MainActor in self?.level = peak }
        }

        task = recognizer.recognitionTask(with: request) { [weak self] result, _ in
            guard let self, let result else { return }
            Task { @MainActor in
                self.transcript = result.bestTranscription.formattedString
            }
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            cleanUp()
            throw Failure.engine(error.localizedDescription)
        }
        isRecording = true
    }

    /// Stops capturing and returns the final transcript.
    @discardableResult
    func stop() -> String {
        guard isRecording else { return transcript }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        request?.endAudio()
        cleanUp()
        isRecording = false
        level = 0
        return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Abandons the current capture without producing a transcript.
    func cancel() {
        _ = stop()
        transcript = ""
    }

    private func cleanUp() {
        task?.cancel()
        task = nil
        request = nil
        // Deactivating lets other audio resume; failing here is not worth
        // surfacing to the user, whose question already succeeded or failed.
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Peak amplitude of a buffer, normalised to 0...1 for the orb.
    nonisolated static func peakLevel(of buffer: AVAudioPCMBuffer) -> Double {
        guard let channel = buffer.floatChannelData?[0] else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        var peak: Float = 0
        for index in 0..<count {
            peak = max(peak, abs(channel[index]))
        }
        return Double(min(peak * 1.8, 1))   // speech rarely nears full scale
    }
}
