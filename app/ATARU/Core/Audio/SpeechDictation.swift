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

    /// 16 kHz mono copy of this turn's audio, for the server's recogniser.
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

    /// Holds whichever recognition request is current, so the audio tap can
    /// feed it without touching main-actor state from the audio thread.
    ///
    /// The tap used to capture the request directly, which is correct for one
    /// request and impossible for two - and a recording longer than Apple's
    /// per-task limit needs a second one. See `rearm()`.
    private final class RequestBox: @unchecked Sendable {
        private var request: SFSpeechAudioBufferRecognitionRequest?
        private let lock = NSLock()

        func set(_ new: SFSpeechAudioBufferRecognitionRequest?) {
            lock.lock(); defer { lock.unlock() }
            request = new
        }

        func append(_ buffer: AVAudioPCMBuffer) {
            lock.lock(); defer { lock.unlock() }
            request?.append(buffer)
        }

        func endAudio() {
            lock.lock(); defer { lock.unlock() }
            request?.endAudio()
        }
    }

    private let engine = AVAudioEngine()
    private let captured = SampleBuffer()
    private let resampler = Resampler()
    private let requestBox = RequestBox()
    /// Words from the recognition task currently running, replaced whenever it
    /// revises them; flushed into `timedWords` when it ends.
    private var currentWords: [TimedWord] = []
    private var recordingStartedAt: Date?
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

    /// The backend that transcribes a finished turn, set wherever the roster
    /// is warmed. Nil in Demo, and nil is simply the on-device path.
    static var sharedService: ATARUService?
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

    /// Text from recognition tasks that already ended while the microphone
    /// kept running. See `rearm()`.
    private var settled = ""
    /// How far into the recording the current recognition task began, so its
    /// segment timestamps can be placed on the recording's own clock.
    private var taskTimeOffset: TimeInterval = 0

    /// Whether to keep per-word timings and the recorded audio. Off by
    /// default: a question needs neither, and on the call path — where a turn
    /// ends every few seconds — they are pure cost.
    var tracksAudioDetail = false

    /// Word timings for the whole recording, offset across restarts. The
    /// input to `SpeakerSplit`. Empty unless `tracksAudioDetail` is on.
    private(set) var timedWords: [TimedWord] = []

    /// The audio of the last finished recording — the other half of what
    /// diarisation needs. About 4MB a minute at 16 kHz float, so nothing
    /// holds it speculatively; cleared on the next `start()`.
    private(set) var lastCapture: [Float] = []

    /// One recognised word and where it sits in the recording.
    struct TimedWord: Equatable {
        let text: String
        let start: TimeInterval
        let duration: TimeInterval
    }

    /// Whether the audio session is up, and the pending job to give it back.
    private var sessionActive = false
    private var releaseSession: Task<Void, Never>?

    /// Whether this recogniser may configure, activate and deactivate the
    /// shared audio session. True on the Ask tab, where nobody else owns it.
    ///
    /// FALSE DURING A CALL, and that is the whole reason this exists.
    /// `start()` set `.playAndRecord` / `.spokenAudio` with `.duckOthers` and
    /// `.defaultToSpeaker`, and activated - which is a point-by-point undo of
    /// what `CallService.configureAudioSession` deliberately chose:
    ///
    ///  - `.voiceChat` (echo cancellation, the mode a phone call wants) became
    ///    `.spokenAudio`, so the caller heard ATARU's own answers fed back.
    ///  - `.defaultToSpeaker` made the speaker the session's DEFAULT route, so
    ///    clearing the override landed on the speaker again and the call
    ///    screen's speaker toggle had no off position - the exact bug
    ///    `configureAudioSession`'s comment says it exists to avoid.
    ///  - `.allowBluetooth` was dropped, so AirPods fell back to the built-in
    ///    microphone.
    ///  - and it activated the session, which under CallKit is the system's
    ///    job and fighting it loses the route.
    ///
    /// All of it landed on the FIRST turn of every call, because that is the
    /// first `start()`. `AnswerPlayer` and `StreamingAnswerPlayer` each have
    /// this same opt-out for the same reason; dictation was the one path that
    /// still reached for the session mid-call.
    var managesAudioSession = true

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


        // A session already up is left alone. Activating one is not
        // instantaneous, and the microphone only starts hearing once it
        // finishes - so the opening word of a turn lands in the gap and is
        // simply never captured. "What time is it in India" reached the
        // server as "Time is it in India", a sentence the time shortcut's
        // anchored patterns cannot match, so it fell through to the agent and
        // came back wrong. In a call, where turns follow each other closely,
        // that gap was being paid on every single one.
        releaseSession?.cancel()
        releaseSession = nil
        // During a call the session belongs to CallKit and is already
        // configured for voice; this only starts the engine on top of it.
        if managesAudioSession, !sessionActive {
            do {
                let audioSession = AVAudioSession.sharedInstance()
                try audioSession.setCategory(.playAndRecord, mode: .spokenAudio,
                                             options: [.duckOthers, .defaultToSpeaker])
                try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
                sessionActive = true
                AudioSessionOwner.shared.markActive()
            } catch {
                throw Failure.engine(error.localizedDescription)
            }
        }

        transcript = ""
        sawFinal = false
        settled = ""
        timedWords = []
        currentWords = []
        lastCapture = []
        taskTimeOffset = 0
        recordingStartedAt = Date()
        if vocabulary.isEmpty { vocabulary = Self.sharedVocabulary }
        captured.reset()
        resampler.reset()
        try armRecognizer()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        let resampler = self.resampler
        let captured = self.captured
        let requestBox = self.requestBox
        input.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak self] buffer, _ in
            requestBox.append(buffer)
            if let mono = resampler.resample(buffer) { captured.append(mono) }
            let peak = Self.peakLevel(of: buffer)
            Task { @MainActor in self?.level = peak }
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

    /// Starts a recognition task over the audio being captured.
    ///
    /// Called once by `start()`, and again by `rearm()` every time Apple ends
    /// a task while the microphone is still open.
    private func armRecognizer() throws {
        guard let recognizer else { throw Failure.unavailable }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true   // see the type's doc comment
        // Apple's own proper-noun biasing, which this app never used. It is a
        // weaker lever than Whisper's prompt, but it is free and it applies to
        // the live partials the user watches AND to the transcript that stands
        // in whenever ATARU's own engine cannot be reached.
        if !vocabulary.isEmpty || !Self.sharedVocabulary.isEmpty {
            let roster = vocabulary.isEmpty ? Self.sharedVocabulary : vocabulary
            request.contextualStrings = Array(roster.prefix(100))
        }
        self.request = request
        requestBox.set(request)

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            let text = result?.bestTranscription.formattedString
            let segments = result?.bestTranscription.segments
            // An error ends the turn as surely as a final result does, and a
            // turn that ends without either would leave `finish()` waiting out
            // its whole budget for a transcript that is never coming.
            let ended = result?.isFinal ?? (error != nil)
            Task { @MainActor in
                if let text { self.absorb(text) }
                if let segments, self.tracksAudioDetail { self.absorb(segments) }
                if ended { self.recognitionEnded() }
            }
        }
    }

    /// Folds this task's text into the recording's transcript.
    ///
    /// A task only ever reports what IT heard, so once a recording has needed
    /// more than one, the live transcript is everything settled so far plus
    /// what the current task has. Assigning `text` straight to `transcript`
    /// was right while a recording could only have one task, and would erase
    /// the first minute of a long one.
    private func absorb(_ text: String) {
        transcript = settled.isEmpty ? text : settled + " " + text
    }

    private func absorb(_ segments: [SFTranscriptionSegment]) {
        currentWords = segments.map {
            TimedWord(text: $0.substring,
                      start: taskTimeOffset + $0.timestamp,
                      duration: $0.duration)
        }
    }

    /// A recognition task has ended. If the microphone is still open, that is
    /// not the end of the recording.
    ///
    /// Apple caps a single on-device recognition task — around a minute — and
    /// ends it with an error rather than a final result. For a question that
    /// never mattered; for a dictated note it is the whole feature, because
    /// everything after the cap simply went unheard while the user watched a
    /// transcript that had silently stopped growing.
    private func recognitionEnded() {
        timedWords.append(contentsOf: currentWords)
        currentWords = []

        guard isRecording else {
            deliverFinal()
            return
        }
        settled = transcript
        taskTimeOffset = recordingStartedAt.map { Date().timeIntervalSince($0) } ?? taskTimeOffset
        task = nil
        request = nil
        requestBox.set(nil)
        // If Apple will not give us another task, the recording carries on
        // capturing audio regardless: the Orin still gets the whole thing, and
        // that is the transcript that matters.
        try? armRecognizer()
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
        requestBox.endAudio()
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
            // Apple's final transcript is the answer now rather than a
            // fallback behind an on-device Whisper, so it is worth the longer
            // wait: see the note above, and the removal of WhisperTranscriber.
            let budget: Double = 2.0
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

    /// Ends the recording and returns what was recognised while it ran.
    ///
    /// ## Why dictating a note does not use `finish()`
    ///
    /// `finish()` exists to produce the best possible reading of a QUESTION,
    /// and it earns its cost there: a question is a few seconds long, one
    /// mangled proper noun changes the answer, and the user is waiting for a
    /// reply anyway. So it ships the audio to the Orin and lets Whisper have
    /// the last word.
    ///
    /// Every one of those premises is false for a note. A note runs for
    /// minutes, so the upload is megabytes and Whisper's decode is long — past
    /// the 12s ceiling in `RemoteTranscriber` more often than not. Nobody is
    /// waiting on a reply, so the round trip buys nothing but delay. And the
    /// user has been WATCHING the transcript the whole time, which makes any
    /// answer other than "what you just saw" look like a bug — which is
    /// exactly how it looked: a pause, and then "I didn't hear anything".
    ///
    /// So capture ends here. This is the shape the Next.js FlowList project
    /// uses and the reason its dictation is dependable: the recogniser's own
    /// accumulated text IS the result, `stop()` hands it back immediately, and
    /// the server only ever sees text. Nothing downstream can turn a heard
    /// note into silence, because there is no longer anything downstream.
    func finishLocally() async -> String {
        let text = await endAudioAwaitingFinal()
        if tracksAudioDetail { lastCapture = captured.drain() } else { captured.reset() }
        // The accumulated transcript is the floor. `endAudioAwaitingFinal` can
        // come back empty if Apple's last task died without a final result,
        // and losing the first two minutes of a note to that is not acceptable
        // when the words are sitting right here.
        if text.isEmpty {
            return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    /// The final question: the server's name-biased read when it answers,
    /// Apple's otherwise.
    ///
    /// Separate from `stop()` because transcription is asynchronous and the
    /// old signature is synchronous. Callers that only need to abandon audio
    /// (mute mid-sentence) keep using `stop()`; callers that are about to ASK
    /// something use this, because this is where the proper nouns get fixed.
    func finish() async -> String {
        let apple = await endAudioAwaitingFinal()
        let samples = captured.drain()
        if tracksAudioDetail { lastCapture = samples }
        // ATARU's own Whisper first. It is the same engine the phone used to
        // carry, with the same name biasing, except it is already loaded and
        // the roster is attached at the server - so there is no cold start to
        // wait out and no 632MB to hold. See RemoteTranscriber.
        if let service = Self.sharedService,
           let remote = await service.transcribe(samples: samples) {
            // AN EMPTY REMOTE RESULT MUST NOT ERASE A TRANSCRIPT WE HAVE.
            //
            // `RemoteTranscriber` returns "" deliberately, to mean "the server
            // decided there was nothing there" as distinct from nil, "the
            // server did not answer" - so that a rejected hallucination is not
            // handed to a less careful engine. That contract is right, and it
            // was being applied one step too far: "" came back through this
            // `if let`, overwrote `transcript`, and was returned as the result,
            // so a note the user had just WATCHED being transcribed on screen
            // came back "I didn't hear anything".
            //
            // The distinction that was missing: refusing to reach for a WORSE
            // engine is not the same as throwing away the text the recogniser
            // already produced while the audio was being recorded. If Apple
            // heard words, those words are the answer.
            let decided = remote.trimmingCharacters(in: .whitespacesAndNewlines)
            if !decided.isEmpty {
                transcript = decided
                return decided
            }
            if !apple.isEmpty { return apple }
            return ""
        }
        // OFF THE NETWORK, THIS IS THE ANSWER (2026-08-16).
        //
        // There used to be a second engine here: WhisperKit, running the model
        // on this phone, tried after Apple and preferred when it succeeded.
        // Its whole value was proper-noun biasing away from the tailnet - it
        // could be told that "Saikat Chaudhuri" was likely, and Apple's
        // recogniser cannot be.
        //
        // It is gone with the Settings toggle that armed it, on Arya's order.
        // The measured position: on-network the server path is faster AND
        // knows the names, the toggle was off, and the model cost ~630MB and
        // about a minute of every cold start. THE TRADE, stated plainly: off
        // the network, dictation still works and is Apple's, unbiased - so
        // names get mangled exactly as they did before WhisperKit arrived.
        // Restoring it means restoring the toggle, the package and this
        // branch together.
        return apple
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
        requestBox.set(nil)
        recordingStartedAt = nil
        scheduleSessionRelease()
    }

    /// Gives the audio session back, but not straight away.
    ///
    /// Deactivating lets whatever was playing resume, so it has to happen -
    /// but doing it the instant a turn ends means the next turn pays the
    /// activation cost again, and the opening word is lost in it. During a
    /// call the next turn is seconds away, so the session is held briefly and
    /// released only if nothing else needs it.
    private func scheduleSessionRelease() {
        // Never during a call: the session being released would be CallKit's,
        // and deactivating it mid-call drops the route for everyone.
        guard managesAudioSession else { return }
        releaseSession?.cancel()
        releaseSession = Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, !self.isRecording, self.sessionActive else { return }
            // ... and NOT while something else is still using the session.
            // This guard was missing, and it is the whole "went quiet
            // mid-sentence" bug: dictation ending armed a 5s timer that
            // deactivated the SHARED session, and since the answer started
            // streaming, playback begins around T+3.3s - so the timer landed
            // in the middle of the sentence. It had no idea the player
            // existed. AudioSessionOwner knows about every user.
            guard !AudioSessionOwner.shared.inUse else {
                // Someone else still needs it; whoever lets go last releases.
                self.sessionActive = false
                return
            }
            self.sessionActive = false
            // Failing here is not worth surfacing to the user, whose question
            // already succeeded or failed.
            try? AVAudioSession.sharedInstance()
                .setActive(false, options: .notifyOthersOnDeactivation)
        }
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
