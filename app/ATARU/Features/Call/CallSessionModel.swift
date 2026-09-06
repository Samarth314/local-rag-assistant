import Combine
import Foundation

/// Runs the conversation inside a call: greet, listen, answer, listen again.
///
/// The Ask tab uses hold-to-speak, which makes the end of a question
/// unambiguous. That does not transfer to a call — nobody holds a button while
/// on the phone, and the screen is often against an ear or locked. So a call
/// detects the end of a turn from silence instead, and loops automatically
/// until somebody hangs up.
///
/// The end of a turn is decided by `EndOfTurn` from two signals - a quiet
/// microphone, or a transcript that has stopped changing while the microphone
/// is quiet - with a hard twenty-second ceiling behind both. Neither signal is
/// sufficient on its own, and the type's own documentation says why each one
/// was added and which failure it answers.
///
/// The other half of a call that feels like a call is barge-in: while ATARU is
/// speaking the microphone stays open, and talking over an answer stops it and
/// becomes the next turn. See `beginBargeIn` and `BargeIn`.
@MainActor
final class CallSessionModel: ObservableObject {

    /// How long the transcript must stay unchanged before the turn is over.
    /// Short enough not to feel like a wait, long enough to survive the pause
    /// in the middle of "what did the landlord say about… the boiler".
    static let silenceGrace: Duration = .milliseconds(1600)
    /// How long the recognised text must stay unchanged before the turn is
    /// over. The SECOND end-of-turn signal, and it exists for the caller the
    /// first one never sees: see `EndOfTurn`.
    static let transcriptStableGrace: Duration = .milliseconds(900)
    /// Mic level above this counts as someone speaking. `level` is a peak
    /// amplitude scaled to 0...1, where room tone sits near zero.
    static let voiceLevel: Double = 0.12
    /// The longest a single turn may run, whatever either gate thinks.
    static let turnDeadline: Duration = .seconds(20)
    /// Consecutive turns that may produce nothing before the call hangs up.
    /// Three covers a cough or a mid-sentence mute; past that nobody is there.
    static let emptyTurnLimit = 3
    /// How many words Apple's partial must hold before an interruption is
    /// believed. One is a cough, a door, or half of ATARU's own sentence
    /// leaking past the echo canceller.
    static let bargeInMinimumWords = 2

    @Published private(set) var phase: VoicePhase = .idle
    /// What the caller is saying right now.
    @Published private(set) var heard: String = ""
    /// The most recent answer, shown under the transcript.
    @Published private(set) var answer: String = ""
    @Published private(set) var exchanges: [VoiceExchange] = []
    /// Mirrors `CallService.isMuted`, driven through `onMuteChanged`.
    @Published private(set) var isMuted = false
    /// The system has the audio route - an alarm, Siri, a cellular call over
    /// the top of this one. Held, not ended: see `setInterrupted`.
    @Published private(set) var isInterrupted = false

    let dictation = SpeechDictation()
    let player = AnswerPlayer()
    let streamPlayer = StreamingAnswerPlayer()

    /// Asked to hang up because the caller said they were done. Wired by the
    /// view that owns both this session and the CallService.
    var onFarewell: (() -> Void)?

    /// Whether the caller may talk over an answer and have it stop.
    ///
    /// Read from the stored configuration rather than plumbed through
    /// `AppState`, deliberately: a call can begin with the app cold - a VoIP
    /// push at 7am - and the switch has to mean the same thing then as it does
    /// when Settings is on screen. `begin()` re-reads it, so flipping it in
    /// Settings takes effect on the next call.
    var bargeInEnabled = AppConfiguration.stored().bargeIn

    /// The caller cut in over the answer. Set by the barge-in monitor; the
    /// next listening turn consumes it and keeps the open microphone instead
    /// of starting a new one.
    private var bargedIn = false
    /// The poll that watches for an interruption while ATARU speaks.
    private var bargeMonitor: Task<Void, Never>?

    private var service: ATARUService
    private var loop: Task<Void, Never>?
    /// The call's WebSocket to the server, opened on the first question and
    /// reused for every turn after. Nil until needed, nil again after a
    /// failure so the next turn reconnects fresh.
    private var stream: VoiceStreamSession?

    init(service: ATARUService) {
        self.service = service
        // CallKit owns the audio session for the whole call. A player that
        // reconfigures it mid-call destroys the `.playAndRecord` route and
        // forces the loudspeaker on — the "speaker button does nothing" bug.
        player.managesAudioSession = false
        streamPlayer.managesAudioSession = false
        // And the recogniser, which was the one path still reaching for the
        // session mid-call: it set `.playAndRecord`/`.spokenAudio` with
        // `.defaultToSpeaker`, no Bluetooth and no echo cancellation, and
        // activated it - on the FIRST turn of every call. See
        // `SpeechDictation.managesAudioSession`.
        dictation.managesAudioSession = false
    }

    /// What drives the orb: the caller's voice while listening, ATARU's own
    /// playback while speaking, quiet otherwise.
    var orbLevel: Double {
        switch phase {
        case .listening: return isMuted ? 0 : dictation.level
        case .speaking: return max(streamPlayer.level, player.level)
        default: return 0
        }
    }

    func update(service: ATARUService) {
        self.service = service
        dropStream()
    }

    /// Lets go of the streaming socket without ending the call.
    ///
    /// Same reason as `VoiceViewModel.dropStream`: a socket that was open
    /// across an outage looks healthy and is not, and on a call the cost of
    /// finding that out lazily is fifteen silent seconds mid-conversation.
    func dropStream() {
        stream?.close()
        stream = nil
    }

    // MARK: - Lifecycle

    /// Starts the conversation. Call this from `CallService.onAudioActivated`
    /// and no earlier — before the system activates the session, speech goes
    /// nowhere and the recogniser gets no input.
    func begin() {
        guard loop == nil else { return }
        // Picked up per call, so the Settings switch needs no wiring and works
        // on a call that starts with no UI alive.
        bargeInEnabled = AppConfiguration.stored().bargeIn
        loop = Task { await run() }
    }

    /// Stops everything and forgets the turn in progress.
    func end() {
        loop?.cancel()
        loop = nil
        abandonBargeIn()
        dictation.cancel()
        player.stop()
        streamPlayer.stop()
        stream?.close()
        stream = nil
        phase = .idle
        heard = ""
        // The call is over, so a route the system had borrowed is no longer
        // this session's problem. Left set, the next call's loop would park in
        // the interrupted wait and never listen.
        isInterrupted = false
    }

    // MARK: - The loop

    private func run() async {
        guard await dictation.requestAuthorization() else {
            phase = .failed(SpeechDictation.Failure.permissionDenied.localizedDescription)
            return
        }

        // Load the name roster once per call. It only makes dictation more
        // likely to hear a name correctly, so a failure here is silent -
        // an unbiased recogniser is exactly what we had before.
        Task { [service] in
            if let names = try? await service.vocabulary(), !names.isEmpty {
                SpeechDictation.sharedVocabulary = names
            }
        }

        // Greet in the server's voice when it has one, so the call opens
        // sounding like the assistant that will answer. Any failure falls
        // back to the phone's voice - the call must greet regardless.
        let greeting = (try? await service.greeting())
            ?? SpokenAnswer(text: Self.greeting, source: nil, audioURL: nil)
        await speak(greeting)

        // One empty turn must not kill the call. It used to: any turn that
        // produced no text broke this loop, and since nothing hangs up, the
        // line just sat there - connected, silent, dead. A cough that trips
        // the level detector, a mid-sentence mute, a recogniser that had
        // nothing by the deadline: all of those ended the conversation
        // permanently. Now the loop simply listens again, and only gives up
        // after several empty turns in a row - a caller who has genuinely
        // walked away.
        //
        // Giving up now HANGS UP. Breaking the loop alone left exactly the
        // dead line described above - and the morning brief redials when a
        // call is answered but never spoken into (Arya may have fallen back
        // asleep), which it cannot do while the phone is still nominally on a
        // call. `onFarewell` is the same hook the spoken goodbye uses; it ends
        // the CallKit call rather than only this loop.
        var emptyTurns = 0
        while !Task.isCancelled {
            guard let question = await listenForOneTurn() else {
                // A turn the SYSTEM took away is not a caller who has walked
                // off. Counting it would let a run of alarms spend the empty
                // budget and hang up a call he is still on.
                if isInterrupted { continue }
                emptyTurns += 1
                if emptyTurns >= Self.emptyTurnLimit {
                    onFarewell?()
                    break
                }
                continue
            }
            emptyTurns = 0
            guard !Task.isCancelled else { break }
            // "That will be all" ends the call like a call: a goodbye in the
            // assistant's voice, then the hang-up - instead of forcing the
            // caller to fish the phone out and tap End.
            if Farewell.matches(question, lastAnswer: answer) {
                heard = question
                let bye = (try? await service.goodbye())
                    ?? SpokenAnswer(text: "Alright, talk later.", source: nil, audioURL: nil)
                await speak(bye)
                onFarewell?()
                break
            }
            await answerQuestion(question)
        }
        // However the loop ends, don't leave the orb claiming a state that no
        // longer has anything behind it.
        if !Task.isCancelled, phase == .listening || phase == .thinking {
            phase = .idle
        }
    }

    /// Mutes or unmutes the microphone.
    ///
    /// Stops the recogniser outright rather than discarding what it hears.
    /// Muting has to mean the audio is not being processed at all — a mute that
    /// merely drops the transcript still feeds the room to the speech engine,
    /// and on a privacy-first assistant that is the wrong kind of "muted".
    func setMuted(_ muted: Bool) {
        isMuted = muted
        if muted {
            // Including the barge-in window: a muted call must not be holding
            // the microphone open behind an answer either.
            abandonBargeIn()
            dictation.cancel()
            if phase == .listening { phase = .idle }
        }
        // Unmuting does not restart listening from here; the turn loop picks it
        // up on its next pass, so one place decides when to record.
    }

    /// The audio route was taken away, or handed back.
    ///
    /// Deliberately NOT `end()`. An interruption is temporary - a ten-second
    /// alarm at 7:00 against a call at 7:00 is the collision this is for - and
    /// ending the session would hang up the morning call over it. The turn
    /// loop parks in the same wait `isMuted` uses and picks the conversation
    /// back up when the route returns.
    ///
    /// Without this the loop kept listening to a microphone the system had
    /// already stopped: it heard nothing for the full 20-second turn budget,
    /// counted an empty turn, and three of those hang the call up.
    func setInterrupted(_ interrupted: Bool) {
        guard isInterrupted != interrupted else { return }
        isInterrupted = interrupted
        guard interrupted else { return }
        // Whatever was mid-flight is gone with the route; drop it rather than
        // letting a half-captured turn become a question.
        abandonBargeIn()
        dictation.cancel()
        player.stop()
        streamPlayer.stop()
        if phase != .idle { phase = .idle }
    }

    /// Records until the caller stops talking. Returns nil if the turn produced
    /// nothing, which ends the loop rather than spinning on an empty mic.
    private func listenForOneTurn() async -> String? {
        // Wait rather than record into a void. A muted call holds the line open
        // and picks up the moment it is unmuted - and an interrupted one waits
        // in exactly the same place, for the same reason.
        while isMuted || isInterrupted, !Task.isCancelled {
            if phase != .idle { phase = .idle }
            try? await Task.sleep(for: .milliseconds(200))
        }
        guard !Task.isCancelled else { return nil }

        // THE CALLER CUT IN, so the microphone is already open and already
        // holding the first words of what they are saying. Restarting it here
        // would throw away exactly those words - the ones barge-in exists to
        // catch - and re-open a recogniser that is already running.
        let continuing = bargedIn && dictation.isRecording
        bargedIn = false
        if !continuing {
            do {
                try dictation.start()
            } catch {
                phase = .failed(error.localizedDescription)
                return nil
            }
        }

        phase = .listening
        heard = continuing ? dictation.transcript : ""

        var lastTranscript = heard
        // Two observations, and `EndOfTurn` owns the decision between them: a
        // microphone that has gone quiet, and a transcript that has stopped
        // changing while nothing is crossing the level gate. Audio level is
        // still ground truth about whether somebody is speaking - it is what
        // stops a stalled recogniser reading as an ending - but it cannot see
        // a caller who never crosses the threshold at all, and that caller
        // used to wait out the whole twenty seconds. See `EndOfTurn`.
        //
        // A barge-in that opened this turn already cleared the level gate and
        // already has text, so both observations start from now rather than
        // making the caller produce them a second time.
        let opened = ContinuousClock.now
        var lastVoiceAt: ContinuousClock.Instant? = continuing ? opened : nil
        var transcriptSettledAt: ContinuousClock.Instant? = continuing ? opened : nil
        // Give the caller a moment to start before silence counts against them.
        let deadline = ContinuousClock.now + Self.turnDeadline
        var ending = TurnEnd.keepListening

        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(120))
            // Muted mid-sentence: drop what was heard rather than answering
            // half a question the user decided not to finish asking. An
            // interruption mid-sentence is the same discard, and `run()` knows
            // not to count it as a silent caller.
            if isMuted || isInterrupted { _ = dictation.stop(); return nil }

            let now = ContinuousClock.now
            let current = dictation.transcript
            if current != lastTranscript {
                lastTranscript = current
                heard = current
                transcriptSettledAt = now
            }

            if dictation.level > Self.voiceLevel { lastVoiceAt = now }

            ending = EndOfTurn.decide(now: now,
                                      deadline: deadline,
                                      lastVoiceAt: lastVoiceAt,
                                      transcript: current,
                                      transcriptSettledAt: transcriptSettledAt)
            if ending != .keepListening { break }
        }
        voiceLog.notice("turn ended: \(ending.reason, privacy: .public)")

        let question = await dictation.finish()
        return question.isEmpty ? nil : question
    }

    // MARK: - Barge-in

    /// Opens the microphone for the duration of an answer, so the caller can
    /// cut in over it.
    ///
    /// ## Why this is worth the risk it carries
    ///
    /// Until now `speak()` awaited playback to its last sample and the
    /// recogniser did not start until the turn after, so talking over ATARU
    /// did nothing at all: the caller either waited out a sentence whose
    /// answer they already had, or repeated themselves into a microphone that
    /// was not on. On a phone call that is the single most unnatural thing
    /// about the loop.
    ///
    /// The risk is the reason the old comment on `speak()` gave for the wait -
    /// "otherwise it hears itself and answers its own answer". Three things
    /// stand between us and that, in order of how much they are worth:
    ///
    ///  1. `AVAudioSession` is in `.voiceChat` mode for the whole call
    ///     (`CallService.configureAudioSession`), which is hardware echo
    ///     cancellation. This is the one that actually does the work, and it
    ///     is the one a Simulator does not have.
    ///  2. The level gate: playback leaking back in sits well under the
    ///     threshold real speech clears.
    ///  3. `BargeIn.isEcho`, a text backstop for whatever gets past both.
    ///
    /// And a kill switch above all three, because a room this misbehaves in is
    /// a room where the feature is simply wrong.
    private func beginBargeIn() {
        guard bargeInEnabled, bargeMonitor == nil else { return }
        guard !isMuted, !isInterrupted, !Task.isCancelled else { return }
        bargedIn = false
        if !dictation.isRecording {
            // Barge-in is a convenience. A microphone that will not open must
            // never take the answer down with it.
            do { try dictation.start() } catch { return }
        }
        bargeMonitor = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(120))
                guard let self, !Task.isCancelled else { return }
                guard self.phase == .speaking, !self.isMuted, !self.isInterrupted else {
                    continue
                }
                guard BargeIn.shouldInterrupt(partial: self.dictation.transcript,
                                              level: self.dictation.level,
                                              spokenSoFar: self.answer) else { continue }
                self.bargedIn = true
                voiceLog.notice("barge-in: the caller cut in over the answer")
                // Silence, now - and everything queued behind it goes too.
                self.player.stop()
                self.streamPlayer.stop()
                return
            }
        }
    }

    /// Closes the barge-in window at the end of an answer.
    ///
    /// The microphone stays open only when the caller actually cut in, because
    /// then it is holding the beginning of their next question. On a clean end
    /// it is closed: keeping it would carry a capture full of ATARU's own
    /// answer into the next turn's audio, and that audio is what Whisper
    /// transcribes.
    private func endBargeIn() {
        bargeMonitor?.cancel()
        bargeMonitor = nil
        if !bargedIn, dictation.isRecording { dictation.cancel() }
    }

    /// Shuts the window and keeps nothing from it - mute, interruption,
    /// hang-up.
    private func abandonBargeIn() {
        bargeMonitor?.cancel()
        bargeMonitor = nil
        bargedIn = false
    }

    private func answerQuestion(_ question: String) async {
        phase = .thinking
        heard = question

        // Read here and carried by hand, rather than looked up further down.
        // Barge-in reopens the microphone as soon as audio starts, and a
        // confidence read after that belongs to a turn that has not been
        // asked yet.
        let stt = dictation.lastConfidence

        // Streaming first: sentence audio starts while the model is still
        // writing. Any failure before audio starts falls through to the
        // blocking path, so a broken socket costs latency, never an answer.
        if await streamAnswer(question, stt: stt) { return }
        guard !Task.isCancelled else { return }

        do {
            let spoken = try await service.ask(question: question, stt: stt)
            guard !Task.isCancelled else { return }
            exchanges.insert(
                VoiceExchange(question: question, answer: spoken.text, source: spoken.source),
                at: 0
            )
            await speak(spoken)
        } catch {
            // Spoken, not just displayed: on a call the screen may not be in
            // view, and silence after a question is indistinguishable from the
            // call having dropped.
            await speak(SpokenAnswer(text: Self.failureLine(for: error), source: nil, audioURL: nil))
        }
    }

    /// Answers over the streaming session. Returns true when the question was
    /// handled (fully, or far enough that re-asking would repeat audio the
    /// caller already heard); false means fall back to the blocking path.
    private func streamAnswer(_ question: String, stt: STTConfidence?) async -> Bool {
        if stream == nil { stream = service.voiceStream() }
        guard let stream else { return false }

        var text = ""
        var audioStarted = false
        var ttsLost = false
        // Every exit from here closes the barge-in window; `endBargeIn` keeps
        // the microphone only when the caller actually cut in.
        defer { endBargeIn() }

        do {
            for try await event in stream.ask(question, stt: stt) {
                guard !Task.isCancelled else {
                    streamPlayer.stop()
                    return true
                }
                // THE CALLER IS TALKING OVER THIS ANSWER. Stop consuming it:
                // waiting out a generation they interrupted is the delay
                // barge-in exists to remove, and the audio is already silent.
                //
                // The socket goes with it. Nothing here changes how the ask
                // stream works - a half-read response simply cannot be handed
                // the next question, so the session is dropped and the next
                // turn opens a fresh one. That costs a reconnect on a turn the
                // caller interrupted, which is the cheap side of the trade.
                if bargedIn {
                    if !text.isEmpty {
                        exchanges.insert(
                            VoiceExchange(question: question, answer: text, source: nil),
                            at: 0
                        )
                    }
                    dropStream()
                    return true
                }
                switch event {
                case .accepted:
                    break
                case .delta(let piece):
                    text += piece
                    answer = text
                case .reset:
                    // What streamed so far was agent scaffolding, not answer.
                    text = ""
                    answer = ""
                case .audioReset:
                    // A guard recalled the streamed answer server-side; drop
                    // the queued audio so the caller hears the correction
                    // instead of the contradicted sentences.
                    streamPlayer.stop()
                case .audioBegin(let sampleRate, let channels, _, let isFiller):
                    try streamPlayer.begin(sampleRate: sampleRate, channels: channels)
                    // A thinking cue is not the answer: if the turn fails
                    // after only the cue played, the fallback must still run,
                    // or the caller gets "Let me check." and then nothing.
                    if !isFiller { audioStarted = true }
                    phase = .speaking
                    // Only the first sentence arms it; the guard inside makes
                    // every later `audioBegin` a no-op.
                    beginBargeIn()
                case .audioChunk(let chunk):
                    streamPlayer.enqueue(chunk)
                case .audioEnd:
                    break
                case .ttsUnavailable:
                    ttsLost = true
                case .done(let spoken, let source, let document):
                    let final = spoken.isEmpty ? text : spoken
                    answer = final
                    // Recorded, but NOT presented: on a call the phone is at
                    // his ear, and throwing a document viewer up mid-call
                    // would be the wrong moment for it. The wall display
                    // already has it.
                    exchanges.insert(
                        VoiceExchange(question: question, answer: final,
                                      source: source, document: document),
                        at: 0
                    )
                    if streamPlayer.isActive {
                        await streamPlayer.finish()
                    } else {
                        // The server answered but could not speak; the phone
                        // can. Same voice as every other fallback.
                        await speak(SpokenAnswer(text: final, source: source, audioURL: nil))
                    }
                    _ = ttsLost  // recorded for symmetry; the speak above covers it
                    return true
                }
            }
            // The stream ended without `done` - a half-answer at best.
            throw VoiceStreamError.protocolViolation("stream ended early")
        } catch {
            streamPlayer.stop()
            self.stream = nil
            if audioStarted {
                // The caller already heard part of this answer. Re-asking
                // through the fallback would replay it; record what we have
                // and move on to the next turn instead.
                if !text.isEmpty {
                    exchanges.insert(
                        VoiceExchange(question: question, answer: text, source: nil),
                        at: 0
                    )
                }
                return true
            }
            return false
        }
    }

    /// Speaks and waits for playback to finish - unless the caller talks over
    /// it, which `beginBargeIn` watches for and which stops the player, and so
    /// resolves this wait early through the same completion block.
    private func speak(_ spoken: SpokenAnswer) async {
        phase = .speaking
        answer = spoken.text
        beginBargeIn()

        await withCheckedContinuation { continuation in
            player.play(spoken) { continuation.resume() }
        }
        endBargeIn()
    }

    private static let greeting = "ATARU here. What would you like to know?"

    private static func failureLine(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription
            ?? "Something went wrong reaching your vault."
    }
}

/// Why a listening turn stopped.
enum TurnEnd: Equatable {
    /// Nothing has decided yet.
    case keepListening
    /// Someone spoke, and then the microphone went quiet for the grace period.
    case quiet
    /// The recognised text stopped changing while nothing was crossing the
    /// level gate.
    case settled
    /// The hard ceiling on a single turn.
    case deadline

    /// A fixed word for the log. Never interpolate the transcript.
    var reason: String {
        switch self {
        case .keepListening: return "still-listening"
        case .quiet: return "quiet"
        case .settled: return "settled"
        case .deadline: return "deadline"
        }
    }
}

/// The whole end-of-turn decision, as a pure function of the clock and two
/// observations. Extracted from the listening loop so it can be tested without
/// a microphone, which is the only way this logic ever gets checked.
///
/// ## Two signals, because one of them cannot see a quiet caller
///
/// The original gate was level only: a turn ended when the microphone had been
/// under `voiceLevel` for `silenceGrace`. That is ground truth about whether
/// someone is still speaking and it is why it was chosen - but it has a blind
/// spot with no floor to it. A caller who never crosses 0.12 at all - held
/// away from the face, a soft voice, a bad route - never sets `lastVoiceAt`,
/// so the gate never arms, and the turn runs the full twenty seconds before
/// anything is asked. The whole question is spoken, recognised, sitting in the
/// transcript, and nothing happens with it for twenty seconds.
///
/// So a second signal: the recognised text has stopped changing. That is the
/// signal the loop originally used and deliberately abandoned, because a
/// recogniser that STALLS looks exactly like a caller who stopped talking, and
/// turns were being cut off mid-sentence ("When was the last time I got an
/// email from"). The protection that was missing then is available now for
/// free: a stall while somebody is still audibly talking keeps `lastVoiceAt`
/// fresh. So `settled` additionally requires that nothing has crossed the
/// level gate recently - it can only fire when the level gate cannot see
/// anybody, which is precisely the caller it was added for.
enum EndOfTurn {

    static func decide(now: ContinuousClock.Instant,
                       deadline: ContinuousClock.Instant,
                       lastVoiceAt: ContinuousClock.Instant?,
                       transcript: String,
                       transcriptSettledAt: ContinuousClock.Instant?,
                       silenceGrace: Duration = CallSessionModel.silenceGrace,
                       stableGrace: Duration = CallSessionModel.transcriptStableGrace)
        -> TurnEnd {
        // Whichever fires first, and the level gate is the one to trust when
        // both could.
        if let voiced = lastVoiceAt, now - voiced > silenceGrace { return .quiet }
        if let settledAt = transcriptSettledAt,
           now - settledAt > stableGrace,
           wordCount(transcript) >= 1,
           // Nothing audible in the same window: a recogniser that stalled
           // under a caller who is still talking must not read as an ending.
           lastVoiceAt.map({ now - $0 > stableGrace }) ?? true {
            return .settled
        }
        if now >= deadline { return .deadline }
        return .keepListening
    }

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }
}

/// Whether what the microphone picks up while ATARU is speaking is the caller
/// cutting in, or ATARU hearing itself.
enum BargeIn {

    /// - Parameters:
    ///   - partial: Apple's live transcript for the open microphone.
    ///   - level: the microphone's peak level right now, 0...1.
    ///   - spokenSoFar: the answer currently being read out, which is the text
    ///     an echo would look like.
    static func shouldInterrupt(partial: String,
                                level: Double,
                                spokenSoFar: String,
                                voiceLevel: Double = CallSessionModel.voiceLevel,
                                minimumWords: Int = CallSessionModel.bargeInMinimumWords)
        -> Bool {
        // Both halves are required, and neither is sufficient. Level alone is
        // a door closing; words alone are the answer leaking back in under a
        // whisper of room tone.
        guard level > voiceLevel else { return false }
        let heard = words(in: partial)
        guard heard.count >= minimumWords else { return false }
        return !isEcho(heard, of: spokenSoFar)
    }

    /// True when everything the recogniser produced appears, in that order and
    /// unbroken, inside the answer being spoken.
    ///
    /// A backstop behind hardware echo cancellation rather than a substitute
    /// for it. Contiguity is what keeps it honest: a caller who happens to
    /// reuse a word ATARU just said is not echoing, and this only fires when
    /// the whole partial is a run lifted straight out of the answer.
    static func isEcho(_ heard: [String], of spoken: String) -> Bool {
        guard !heard.isEmpty else { return true }
        let said = words(in: spoken)
        guard said.count >= heard.count else { return false }
        for start in 0...(said.count - heard.count) where
            Array(said[start..<(start + heard.count)]) == heard {
            return true
        }
        return false
    }

    static func words(in text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" })
            .map(String.init)
    }
}

/// Decides whether an utterance means "I'm done with this call".
///
/// Two shapes count: an explicit sign-off ("that will be all", "goodbye"),
/// or a bare "no" - but the bare form only when the assistant's last answer
/// ended with a question, because "no" as the whole reply to "do you need
/// anything else?" is a goodbye, while "no" out of nowhere may be the start
/// of a correction the recognizer cut short.
enum Farewell {

    /// Sign-offs matched anywhere in the utterance.
    private static let phrases = [
        "that will be all", "that'll be all", "that is all", "thats all",
        "that's all", "nothing else", "that's it for now", "thats it for now",
        "that's everything", "thats everything", "we're done", "were done",
        "i'm all set", "im all set", "all set thanks", "talk to you later",
        "talk later", "goodbye", "good bye",
    ]

    /// Whole-utterance negatives, honored only after a question.
    private static let bareNegatives: Set<String> = [
        "no", "nope", "nah", "no thanks", "no thank you", "nothing",
        "not right now", "im good", "i'm good", "im okay", "i'm okay",
        "no that's it", "no thats it", "bye",
    ]

    static func matches(_ utterance: String, lastAnswer: String) -> Bool {
        let normalized = normalize(utterance)
        guard !normalized.isEmpty else { return false }
        if phrases.contains(where: { normalized.contains($0) }) { return true }
        if bareNegatives.contains(normalized) {
            return lastAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
                .hasSuffix("?")
        }
        return false
    }

    private static func normalize(_ text: String) -> String {
        let lowered = text.lowercased()
        let kept = lowered.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar)
                || scalar == "'" || scalar == " " {
                return Character(scalar)
            }
            return " "
        }
        return String(kept).split(separator: " ").joined(separator: " ")
    }
}
