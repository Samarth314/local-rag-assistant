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

    /// 16 kHz mono copy of this turn's audio, for WhisperKit.
    ///
    /// Deliberately NOT main-actor state. Appending each ~23 ms buffer through
    /// `Task { @MainActor }` flooded the main actor, which starved
    /// `SFSpeechRecognizer`'s partial updates - and the call loop reads a
    /// stalled transcript as silence, so it ended turns mid-sentence
    /// ("When was the last time I got an email from"). The audio thread now
    /// appends under a lock and never hops.
    private final class SampleBuffer: @unchecked Sendable {
        private var samples: [Float] = []
        private let lock = NSLock()

        func append(_ new: [Float]) {
            lock.lock(); defer { lock.unlock() }
            samples.append(contentsOf: new)
        }

        func drain() -> [Float] {
            lock.lock(); defer { lock.unlock() }
            let out = samples
            samples.removeAll(keepingCapacity: false)
            return out
        }

        func reset() {
            lock.lock(); defer { lock.unlock() }
            samples.removeAll(keepingCapacity: true)
        }
    }

    /// Resamples capture buffers to Whisper's 16 kHz mono, keeping ONE
    /// converter alive across the turn. The first version built a new
    /// `AVAudioConverter` for every ~23 ms buffer on the audio tap thread -
    /// an allocation per buffer, and a resampler whose filter state reset at
    /// every buffer boundary, which stitches faint artifacts into the audio
    /// Whisper decodes. A persistent converter keeps its filter state across
    /// buffers, so the 16 kHz stream is continuous.
    private final class Resampler: @unchecked Sendable {
        private let lock = NSLock()
        private var converter: AVAudioConverter?
        private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                           sampleRate: 16_000, channels: 1,
                                           interleaved: false)!

        func resample(_ buffer: AVAudioPCMBuffer) -> [Float]? {
            if buffer.format.sampleRate == 16_000, buffer.format.channelCount == 1 {
                guard let data = buffer.floatChannelData?[0] else { return nil }
                return Array(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
            }
            lock.lock(); defer { lock.unlock() }
            if converter == nil || converter?.inputFormat != buffer.format {
                converter = AVAudioConverter(from: buffer.format, to: target)
            }
            guard let converter else { return nil }
            let ratio = 16_000 / buffer.format.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1_024)
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
            var supplied = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if supplied { status.pointee = .noDataNow; return nil }
                supplied = true
                status.pointee = .haveData
                return buffer
            }
            guard error == nil, let data = out.floatChannelData?[0] else { return nil }
            return Array(UnsafeBufferPointer(start: data, count: Int(out.frameLength)))
        }

        /// Fresh filter state for a fresh turn.
        func reset() {
            lock.lock(); defer { lock.unlock() }
            converter?.reset()
        }
    }

    private let engine = AVAudioEngine()
    private let captured = SampleBuffer()
    private let resampler = Resampler()
    /// Proper nouns to expect - set from the backend's correspondent list.
    ///
    /// Seeded from `sharedVocabulary` at capture time. It must NEVER be
    /// fetched on the press path: awaiting the server between the button
    /// going down and the microphone opening meant a hold recorded nothing
    /// and the release was ignored, so every question came back "I didn't
    /// hear anything".
    var vocabulary: [String] = []

    /// Roster shared by every dictation instance, refreshed in the background
    /// when the backend changes. Empty just means unbiased transcription.
    static var sharedVocabulary: [String] = []
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    /// Waiting for Apple's *final* transcript, while a turn is ending.
    ///
    /// Partial results arrive behind the speech that produced them, so the
    /// value of `transcript` at the instant the microphone closes is missing
    /// the last word or two of what was said. `stop()` used to end the audio
    /// and cancel the recognition task in the same breath, discarding the
    /// final result Apple was about to deliver - which is how "turn the lamp
    /// on" reached the server as "Turn the lamp", a command with its one
    /// decisive word removed, and as bare "Turn" on the worst turns.
    private var finalWaiter: CheckedContinuation<String, Never>?
    private var sawFinal = false

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
        sawFinal = false
        if vocabulary.isEmpty { vocabulary = Self.sharedVocabulary }
        captured.reset()
        resampler.reset()
        // Loading is idempotent; the first call downloads, later ones no-op.
        WhisperTranscriber.shared.prepare()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        let resampler = self.resampler
        let captured = self.captured
        input.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak self] buffer, _ in
            request.append(buffer)
            if let mono = resampler.resample(buffer) { captured.append(mono) }
            let peak = Self.peakLevel(of: buffer)
            Task { @MainActor in self?.level = peak }
        }

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            let text = result?.bestTranscription.formattedString
            // An error ends the turn as surely as a final result does, and a
            // turn that ends without either would leave `finish()` waiting out
            // its whole budget for a transcript that is never coming.
            let ended = result?.isFinal ?? (error != nil)
            Task { @MainActor in
                if let text { self.transcript = text }
                if ended { self.deliverFinal() }
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

    /// Stops capturing and returns whatever has been transcribed so far.
    ///
    /// Synchronous, so it cannot wait for Apple's final result - which makes
    /// it right for abandoning audio (mute, cancel) and wrong for ending a
    /// question. Anything about to be ASKED goes through `finish()`.
    @discardableResult
    func stop() -> String {
        guard isRecording else { return transcript }
        closeMicrophone()
        cleanUp()
        deliverFinal()      // nothing is coming now; release any waiter
        return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Everything `stop()` does except ending the recognition task, so the
    /// recogniser is still alive to deliver its last result.
    private func closeMicrophone() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        request?.endAudio()
        isRecording = false
        level = 0
    }

    /// Hands Apple's finished transcript to whoever is waiting for it, once.
    private func deliverFinal() {
        sawFinal = true
        guard let waiter = finalWaiter else { return }
        finalWaiter = nil
        waiter.resume(returning: transcript.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Ends capture and gives Apple a moment to finish the sentence.
    ///
    /// The budget is small and it is a ceiling, not a delay: the final result
    /// normally lands within a few hundred milliseconds of the audio ending,
    /// and this returns the instant it does. It is longer when Whisper cannot
    /// answer, because then this transcript is not a fallback - it is the
    /// question.
    private func endAudioAwaitingFinal() async -> String {
        guard isRecording else {
            return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        closeMicrophone()
        if !sawFinal {
            let budget: Double = WhisperTranscriber.shared.isReady ? 1.0 : 2.0
            let text = await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
                finalWaiter = cont
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(budget))
                    self.deliverFinal()
                }
            }
            cleanUp()
            return text
        }
        cleanUp()
        return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The final question: Whisper's read when a model is loaded, Apple's
    /// otherwise.
    ///
    /// Separate from `stop()` because transcription is asynchronous and the
    /// old signature is synchronous. Callers that only need to abandon audio
    /// (mute mid-sentence) keep using `stop()`; callers that are about to ASK
    /// something use this, because this is where the proper nouns get fixed.
    func finish() async -> String {
        let apple = await endAudioAwaitingFinal()
        let samples = captured.drain()
        guard WhisperTranscriber.shared.isReady else { return apple }
        // Hard ceiling. A question that never comes back is worse than one
        // transcribed slightly worse: the app sat on "Thinking" forever the
        // first time this path misbehaved, so Whisper now gets a fixed budget
        // and Apple's transcript wins by default if it overruns.
        // 10s ceiling, enforced by the transcriber itself - a question that
        // never comes back is worse than one transcribed slightly worse.
        let whisperText = await WhisperTranscriber.shared.transcribe(
            samples: samples, vocabulary: vocabulary, timeout: 10)
        guard let whisper = whisperText else { return apple }
        // Whisper writes "[BLANK_AUDIO]" and similar for silence; a bracketed
        // artefact is not a question, so fall back rather than ask it.
        let cleaned = whisper.replacingOccurrences(
            of: "\\[[^\\]]+\\]", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return apple }
        transcript = cleaned
        return cleaned
    }

    /// Abandons the current capture without producing a transcript.
    func cancel() {
        _ = stop()
        captured.reset()
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
