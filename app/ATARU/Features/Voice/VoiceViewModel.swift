import Foundation
import SwiftUI

/// Drives one spoken exchange: listen, ask, speak.
///
/// The phase machine is deliberately explicit rather than derived from a pile
/// of booleans — the orb, the button and VoiceOver all read from it, and they
/// must never disagree about what the assistant is doing.
@MainActor
final class VoiceViewModel: ObservableObject {

    @Published private(set) var phase: VoicePhase = .idle
    @Published private(set) var exchanges: [VoiceExchange] = []
    /// What the user is saying right now, shown while they hold the button.
    @Published private(set) var partialTranscript: String = ""
    /// Set when dictation is unavailable, so the UI can offer typing.
    @Published var typedQuestion: String = ""
    @Published var isShowingTypeField = false
    /// The document a pull-up turn opened. Setting it presents the viewer;
    /// clearing it puts the viewer away and leaves the answer on screen.
    @Published var presentedDocument: DocumentRef?

    let dictation = SpeechDictation()
    let player = AnswerPlayer()
    /// Speaks the answer while the model is still writing it. See `ask`.
    let streamPlayer = StreamingAnswerPlayer()

    private var service: ATARUService
    private var askTask: Task<Void, Never>?
    /// Guarantees the turn leaves .speaking - see armPhaseWatchdog().
    private var phaseWatchdog: Task<Void, Never>?
    private var stream: VoiceStreamSession?
    /// Whether the orb is still held. `beginListening` has real async work
    /// before the mic opens (permission check, audio session, engine start),
    /// so a quick tap can RELEASE before `phase` ever reaches `.listening` -
    /// `endListening`'s guard then drops the release, and the mic opens with
    /// the button already up and stays stuck on "Listening" with nobody
    /// holding it. This flag lets the open notice the release already
    /// happened and stand down.
    private var holdActive = false

    init(service: ATARUService) {
        self.service = service
    }

    /// Called when the environment's service changes (Demo ⇄ Live).
    func update(service: ATARUService) {
        self.service = service
    }

    var canRecord: Bool { phase.allowsNewQuestion }

    /// What drives the orb: the user's voice while listening, the answer's
    /// own playback while speaking, quiet otherwise.
    var orbLevel: Double {
        switch phase {
        case .listening: return dictation.level
        case .speaking: return max(streamPlayer.level, player.level)
        default: return 0
        }
    }

    // MARK: - Listening

    func beginListening() async {
        guard phase.allowsNewQuestion else { return }
        holdActive = true
        guard await dictation.requestAuthorization() else {
            phase = .failed(SpeechDictation.Failure.permissionDenied.localizedDescription)
            return
        }
        guard holdActive else { return }   // released while permissions settled
        do {
            try dictation.start()
            guard holdActive else {
                // A tap, not a hold: the finger left before the mic finished
                // opening. There is nothing worth transcribing in a few
                // milliseconds of audio, so this is a cancel, not a question.
                dictation.cancel()
                return
            }
            partialTranscript = ""
            phase = .listening
            Haptics.fire(.tap)
            // Refresh for the NEXT turn, off the critical path.
            if SpeechDictation.sharedVocabulary.isEmpty {
                Task { [service] in
                    if let names = try? await service.vocabulary(), !names.isEmpty {
                        SpeechDictation.sharedVocabulary = names
                    }
                }
            }
        } catch let failure as SpeechDictation.Failure {
            phase = .failed(failure.localizedDescription)
            // On-device dictation missing is not a dead end: typing still works.
            if failure == .unavailable { isShowingTypeField = true }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func endListening() {
        holdActive = false
        guard phase == .listening else { return }
        // Whisper's pass is asynchronous, so the question is settled in a
        // Task; `.thinking` is set first so the UI never shows an idle orb
        // between the button release and the answer starting.
        phase = .thinking
        Task {
            let question = await dictation.finish()
            partialTranscript = ""
            guard !question.isEmpty else {
                phase = .failed(SpeechDictation.Failure.noSpeechDetected.localizedDescription)
                return
            }
            ask(question)
        }
    }

    func cancelListening() {
        holdActive = false
        dictation.cancel()
        partialTranscript = ""
        phase = .idle
    }

    // MARK: - Asking

    func submitTypedQuestion() {
        let question = typedQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        typedQuestion = ""
        isShowingTypeField = false
        ask(question)
    }

    func ask(_ question: String) {
        askTask?.cancel()
        phase = .thinking
        askTask = Task { [service] in
            // Streaming first, because the wait is the whole complaint.
            //
            // Asking and then speaking is two serial waits: the model writes
            // the entire answer, and only then does anything get synthesized.
            // Measured on the vault, a question that needs the agent is ~8s of
            // model and several more of speech, and the phone is silent for
            // all of it. The call path has streamed since it was built - the
            // first sentence is spoken while the rest is still being written -
            // and there was never a reason for a held-orb question to be any
            // slower than the same question asked on a call.
            if await self.streamAnswer(question) { return }
            guard !Task.isCancelled else { return }
            do {
                let answer = try await service.ask(question: question)
                guard !Task.isCancelled else { return }
                record(question: question, answer: answer)
                speak(answer)
            } catch is CancellationError {
                // Deliberate: the user asked something else.
            } catch {
                guard !Task.isCancelled else { return }
                phase = .failed((error as? APIError)?.localizedDescription
                                ?? error.localizedDescription)
            }
        }
    }

    /// Answers over the streaming session, returning false to fall back to the
    /// blocking path - which stays exactly as it was, and is what Demo and any
    /// server without a voice engine still use.
    private func streamAnswer(_ question: String) async -> Bool {
        if stream == nil { stream = service.voiceStream() }
        guard let stream else { return false }

        var text = ""
        var spokenAnything = false
        do {
            for try await event in stream.ask(question) {
                guard !Task.isCancelled else {
                    streamPlayer.stop()
                    return true
                }
                switch event {
                case .accepted:
                    break
                case .delta(let piece):
                    text += piece
                case .reset:
                    // What streamed so far was agent scaffolding, not answer.
                    text = ""
                case .audioReset:
                    // A guard recalled the streamed answer server-side. What
                    // is queued must not be heard; the next audio_begin
                    // reopens the player for the correction, exactly as
                    // after a hang-up.
                    streamPlayer.stop()
                case .audioBegin(let sampleRate, let channels, _, let isFiller):
                    try streamPlayer.begin(sampleRate: sampleRate, channels: channels)
                    // A thinking cue is not the answer. If the turn dies after
                    // only the cue played, the fallback still has to run or the
                    // question ends at "Let me check."
                    if !isFiller { spokenAnything = true }
                    phase = .speaking
                    armPhaseWatchdog()
                case .audioChunk(let chunk):
                    armPhaseWatchdog()   // audio is flowing; push the deadline out
                    streamPlayer.enqueue(chunk)
                case .audioEnd, .ttsUnavailable:
                    break
                case .done(let spoken, let source, let document):
                    let final = spoken.isEmpty ? text : spoken
                    record(question: question,
                           answer: SpokenAnswer(text: final, source: source, audioURL: nil),
                           document: document)
                    // Opening it is the point of asking for it: a pull-up
                    // turn puts the file on screen here as well as on the
                    // wall, so he can zoom and scroll it in his hand.
                    if let document { presentedDocument = document }
                    if streamPlayer.isActive {
                        await streamPlayer.finish()
                        if phase == .speaking { phase = .idle }
                    } else {
                        // The server answered but could not speak it. The
                        // phone can, in the same voice as every other
                        // fallback.
                        speak(SpokenAnswer(text: final, source: source, audioURL: nil))
                    }
                    return true
                }
            }
            throw VoiceStreamError.protocolViolation("stream ended early")
        } catch {
            streamPlayer.stop()
            // Once real answer audio has played, re-asking would repeat it
            // aloud. Better a truncated answer than the first half twice.
            if spokenAnything {
                phase = .idle
                return true
            }
            return false
        }
    }

    /// Replays an earlier answer without asking again.
    func replay(_ exchange: VoiceExchange) {
        guard phase.allowsNewQuestion else { return }
        speak(SpokenAnswer(text: exchange.answer, source: exchange.source, audioURL: nil))
    }

    /// Ends the turn - properly.
    ///
    /// This used to stop the two players and set `phase = .idle`, which is
    /// cosmetic: the ask task kept running and the websocket stayed open (the
    /// server logged code=1005 when the OS eventually reaped it). So on a
    /// wedged turn, tapping Stop changed nothing the user could see and there
    /// was no way back short of force-quitting the app. Everything that makes
    /// up the turn is now torn down.
    func stopSpeaking() {
        phaseWatchdog?.cancel()
        phaseWatchdog = nil
        askTask?.cancel()
        askTask = nil
        stream?.close()
        stream = nil
        player.stop()
        streamPlayer.stop()
        phase = .idle
    }

    /// Last resort: leave the speaking phase even if socket, server and audio
    /// all vanish at once.
    ///
    /// Re-armed on entering `.speaking` and on every audio chunk, so a healthy
    /// answer keeps pushing it out and it only fires when genuinely nothing
    /// has arrived. Without it, one stalled turn left the app reading
    /// "Answering" forever with no route back.
    private func armPhaseWatchdog() {
        phaseWatchdog?.cancel()
        phaseWatchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled, let self, self.phase == .speaking else { return }
            voiceLog.error("phase watchdog fired - tearing down a stalled turn")
            self.stopSpeaking()
        }
    }

    private func record(question: String, answer: SpokenAnswer,
                        document: DocumentRef? = nil) {
        exchanges.insert(
            VoiceExchange(question: question, answer: answer.text,
                          source: answer.source, document: document),
            at: 0
        )
    }

    private func speak(_ answer: SpokenAnswer) {
        phase = .speaking
        armPhaseWatchdog()
        player.play(answer) { [weak self] in
            guard let self else { return }
            // Only return to idle if nothing else has taken over in the
            // meantime — a new question while this one finishes must win.
            if self.phase == .speaking { self.phase = .idle }
        }
    }

    func dismissFailure() {
        if case .failed = phase { phase = .idle }
    }
}
