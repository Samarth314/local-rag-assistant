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
    /// "Hey ATARU", while the app is on screen. See `WakeWordListener`.
    let wake = WakeWordListener()

    /// Whether standby is armed. Persisted, because a mode you have to switch
    /// on every time the app cold-starts is a mode nobody uses.
    @Published var isStandby: Bool {
        didSet {
            guard isStandby != oldValue else { return }
            UserDefaults.standard.set(isStandby, forKey: Self.standbyKey)
            if isStandby {
                Task { await wake.enable() }
            } else {
                standbyGate?.cancel()
                standbyGate = nil
                wake.disable()
            }
        }
    }

    /// What standby is actually doing, mirrored out of the listener so the UI
    /// has something published to watch. See `WakeWordListener.onStatusChange`.
    @Published private(set) var wakeStatus: WakeWordListener.Status = .off

    static let standbyKey = "ataru.wakeword.standby"

    /// The pending "give the microphone back to standby once this turn is
    /// over" job. One at a time; a new hold cancels it.
    private var standbyGate: Task<Void, Never>?
    /// The wake-word turn currently running, so switching standby off or
    /// starting a call can tear it down.
    private var wakeTurn: Task<Void, Never>?

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
        // The UI suite gets a throwaway everything else (see `AppState.init`),
        // and it must get standby off too: a developer whose own phone has the
        // wake word armed would otherwise have every test run open the
        // microphone and answer its own fixtures out loud.
        self.isStandby = RuntimeMode.isUITesting
            ? false
            : UserDefaults.standard.bool(forKey: Self.standbyKey)
        wake.onWake = { [weak self] command in self?.beginWakeTurn(command: command) }
        wake.onStatusChange = { [weak self] status in self?.wakeStatus = status }
        // A hands-free turn is a turn in which the name has just been said, so
        // this recogniser needs to expect it too - and a question that MENTIONS
        // ATARU is transcribed better for it either way.
        dictation.contextualBias = WakePhrase.contextualStrings
    }

    /// Opens the microphone if standby was left on. Called from the view once
    /// it is on screen - never from `init`, which runs while a preview or a
    /// test is being built and has no business asking for the microphone.
    func startStandbyIfEnabled() async {
        guard isStandby else { return }
        await wake.enable()
    }

    /// Called when the environment's service changes (Demo ⇄ Live).
    func update(service: ATARUService) {
        self.service = service
        // A socket to the OLD backend is not a socket to this one.
        dropStream()
    }

    /// Lets go of the streaming socket without touching the turn in progress.
    ///
    /// Called when the app comes back online after an outage. A WebSocket that
    /// was open when the tunnel went down does not report anything: it sits
    /// there looking healthy and the next question spends its whole 15s
    /// receive window discovering otherwise before the blocking path takes
    /// over. Reconnecting costs one handshake; not reconnecting costs fifteen
    /// seconds of an orb thinking about nothing.
    func dropStream() {
        stream?.close()
        stream = nil
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
        // A held orb is the user taking the microphone by hand. Standby lets
        // go of it rather than recording the same words twice.
        holdStandby()
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
                releaseStandby()
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
        releaseStandby()
    }

    // MARK: - Standby ("Hey ATARU")

    /// Something else needs the microphone. Standby stays armed, but shuts up.
    ///
    /// The two SpeechDictation instances - standby's and the turn's - each own
    /// an `AVAudioEngine`, and two engines tapping the same input node is how a
    /// wake word turns into a turn that records silence. Only one is ever open.
    func standbyPause() {
        let hadWakeTurn = wakeTurn != nil
        wakeTurn?.cancel()
        wakeTurn = nil
        // A cancelled task does not close a microphone. A wake turn cut short
        // by a call arriving would otherwise leave the recogniser running
        // underneath the call - two engines on one input, which is the exact
        // collision standby exists to avoid.
        if hadWakeTurn, phase == .listening {
            holdActive = false
            dictation.cancel()
            partialTranscript = ""
            phase = .idle
        }
        holdStandby()
    }

    /// The microphone is free again - the app came back to the foreground, or
    /// a call ended. A no-op when standby is off.
    func standbyResume() {
        releaseStandby()
    }

    private func holdStandby() {
        standbyGate?.cancel()
        standbyGate = nil
        wake.pause()
    }

    /// Gives the microphone back to standby, but only once the turn in flight
    /// is genuinely over.
    ///
    /// Resuming the instant a question is SENT would have standby listening
    /// through the answer being spoken - and the recogniser would hear "ATARU"
    /// in ATARU's own voice and wake itself in a loop.
    private func releaseStandby() {
        guard isStandby else { return }
        standbyGate?.cancel()
        standbyGate = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled, !self.phase.allowsNewQuestion {
                try? await Task.sleep(for: .milliseconds(250))
            }
            guard let self, !Task.isCancelled, self.isStandby else { return }
            await self.wake.resume()
        }
    }

    /// The phrase was heard. Run one hands-free turn, then go back to standby.
    ///
    /// `command` is the same-breath question, when there was one: "hey ataru
    /// check the time" is ONE utterance, and standby's own recogniser has
    /// already transcribed all of it. Opening a second microphone to ask again
    /// is how that question used to get lost - by the time the new recogniser
    /// is up, the words are gone. So a command that already exists is asked
    /// directly, and only a bare name gets the cue and a listening turn.
    private func beginWakeTurn(command: String?) {
        guard phase.allowsNewQuestion else {
            releaseStandby()
            return
        }
        wakeTurn?.cancel()
        // HOLD THE AUDIO SESSION ACROSS THE HANDOFF.
        //
        // Standby's recogniser has just closed, which arms
        // `SpeechDictation`'s 5-second deferred deactivation of the SHARED
        // session. The turn's own recogniser opens milliseconds later and runs
        // for up to twelve seconds - so without a retain, the session is torn
        // down from under it at T+5s, mid-question, by an object that has
        // already finished. That is the exact failure `AudioSessionOwner`
        // exists for; standby is simply another user of the session.
        //
        // It matters MORE on the same-breath path, not less: there, no second
        // recogniser opens at all, so nothing else cancels that pending
        // deactivation before the answer starts playing.
        AudioSessionOwner.shared.retain()
        wakeTurn = Task { @MainActor [weak self] in
            // The retain is released however this ends - answered, cancelled
            // by a call, or thrown away by standby being switched off.
            //
            // It does NOT clear `wakeTurn`. By the time a finished turn's
            // teardown runs, standby may already have heard the phrase again
            // and stored a NEW task there, and nilling it then would leave
            // that turn uncancellable.
            defer { AudioSessionOwner.shared.release() }
            guard let self else { return }
            let question: String
            if let command, !command.isEmpty {
                // Already heard. The same haptic the orb and the cue give, so
                // the two ways of asking feel identical from the outside.
                Haptics.fire(.tap)
                question = command
            } else {
                question = await self.listenHandsFree()
            }
            guard !Task.isCancelled else { return }
            guard !question.isEmpty else {
                // Woken by something that was not a question - the television,
                // a passing "Atari". Say nothing and go back to waiting.
                if self.phase == .listening { self.phase = .idle }
                self.releaseStandby()
                return
            }
            self.ask(question)
            await self.askTask?.value
            // `ask` only awaits playback on the streaming path; the blocking
            // one hands the answer to a callback-driven player. Either way
            // standby must not reopen while ATARU is still talking.
            while !Task.isCancelled, self.phase == .speaking {
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    /// Records until the speaker stops, the way a call turn does.
    ///
    /// Reached only when the wake phrase was the WHOLE utterance - "hey ATARU",
    /// pause. A question asked in the same breath never gets here, because
    /// standby's own stream already has it.
    ///
    /// Nobody is holding anything after a wake word, so the end of the question
    /// is judged from a quiet MICROPHONE rather than from a transcript that has
    /// stopped growing - the same ground truth, and the same tuning, the call
    /// loop settled on. See `CallSessionModel.listenForOneTurn`.
    private func listenHandsFree() async -> String {
        do {
            try dictation.start()
        } catch let failure as SpeechDictation.Failure {
            phase = .failed(failure.localizedDescription)
            return ""
        } catch {
            phase = .failed(error.localizedDescription)
            return ""
        }

        partialTranscript = ""
        phase = .listening
        // The existing listening cue, so waking sounds like pressing the orb.
        Haptics.fire(.tap)

        var lastVoiceAt: ContinuousClock.Instant?
        // Shorter than a call's 20s: a call is a conversation with pauses in
        // it, and this is one question asked of a phone across the room.
        let deadline = ContinuousClock.now + .seconds(12)

        while !Task.isCancelled, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(120))
            partialTranscript = dictation.transcript
            if dictation.level > CallSessionModel.voiceLevel {
                lastVoiceAt = ContinuousClock.now
            }
            if let voiced = lastVoiceAt,
               ContinuousClock.now - voiced > CallSessionModel.silenceGrace {
                break
            }
        }

        let question = await dictation.finish()
        partialTranscript = ""
        return question
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
        // Every question ends in an answer being spoken aloud, and standby
        // must not be listening while that happens - see `releaseStandby`.
        holdStandby()
        releaseStandby()
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
        // Stopping an answer is the end of the turn as surely as finishing one
        // is, so standby gets the microphone back here too.
        releaseStandby()
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
