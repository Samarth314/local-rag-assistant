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
/// Silence is judged by the transcript going quiet rather than by input level:
/// the recogniser already distinguishes speech from room noise, and a level
/// threshold picks up traffic, a fan, or a television and never ends the turn.
@MainActor
final class CallSessionModel: ObservableObject {

    /// How long the transcript must stay unchanged before the turn is over.
    /// Short enough not to feel like a wait, long enough to survive the pause
    /// in the middle of "what did the landlord say about… the boiler".
    static let silenceGrace: Duration = .milliseconds(1600)
    /// Mic level above this counts as someone speaking. `level` is a peak
    /// amplitude scaled to 0...1, where room tone sits near zero.
    static let voiceLevel: Double = 0.12

    @Published private(set) var phase: VoicePhase = .idle
    /// What the caller is saying right now.
    @Published private(set) var heard: String = ""
    /// The most recent answer, shown under the transcript.
    @Published private(set) var answer: String = ""
    @Published private(set) var exchanges: [VoiceExchange] = []
    /// Mirrors `CallService.isMuted`, driven through `onMuteChanged`.
    @Published private(set) var isMuted = false

    let dictation = SpeechDictation()
    let player = AnswerPlayer()
    let streamPlayer = StreamingAnswerPlayer()

    /// Asked to hang up because the caller said they were done. Wired by the
    /// view that owns both this session and the CallService.
    var onFarewell: (() -> Void)?

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
        stream?.close()
        stream = nil
    }

    // MARK: - Lifecycle

    /// Starts the conversation. Call this from `CallService.onAudioActivated`
    /// and no earlier — before the system activates the session, speech goes
    /// nowhere and the recogniser gets no input.
    func begin() {
        guard loop == nil else { return }
        loop = Task { await run() }
    }

    /// Stops everything and forgets the turn in progress.
    func end() {
        loop?.cancel()
        loop = nil
        dictation.cancel()
        player.stop()
        streamPlayer.stop()
        stream?.close()
        stream = nil
        phase = .idle
        heard = ""
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
        if let names = try? await service.vocabulary(), !names.isEmpty {
            dictation.vocabulary = names
        }

        // Greet in the server's voice when it has one, so the call opens
        // sounding like the assistant that will answer. Any failure falls
        // back to the phone's voice - the call must greet regardless.
        let greeting = (try? await service.greeting())
            ?? SpokenAnswer(text: Self.greeting, source: nil, audioURL: nil)
        await speak(greeting)

        while !Task.isCancelled {
            guard let question = await listenForOneTurn() else { break }
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
            dictation.cancel()
            if phase == .listening { phase = .idle }
        }
        // Unmuting does not restart listening from here; the turn loop picks it
        // up on its next pass, so one place decides when to record.
    }

    /// Records until the caller stops talking. Returns nil if the turn produced
    /// nothing, which ends the loop rather than spinning on an empty mic.
    private func listenForOneTurn() async -> String? {
        // Wait rather than record into a void. A muted call holds the line open
        // and picks up the moment it is unmuted.
        while isMuted, !Task.isCancelled {
            if phase != .idle { phase = .idle }
            try? await Task.sleep(for: .milliseconds(200))
        }
        guard !Task.isCancelled else { return nil }

        do {
            try dictation.start()
        } catch {
            phase = .failed(error.localizedDescription)
            return nil
        }

        phase = .listening
        heard = ""

        var lastTranscript = ""
        // The turn ends on a QUIET MICROPHONE, not on a transcript that
        // stopped growing. Watching the transcript meant any recogniser stall
        // read as silence: while the Whisper model was downloading in the
        // background the phone was busy enough to lag Apple's partials, and
        // turns were cut off mid-sentence - "When was the last time I got an
        // email from" (no name), "How are" for "hey you there", which then got
        // answered as a finances question. Audio level is ground truth about
        // whether someone is still speaking, whatever the recogniser is doing.
        var lastVoiceAt: ContinuousClock.Instant?
        // Give the caller a moment to start before silence counts against them.
        let deadline = ContinuousClock.now + .seconds(20)

        while !Task.isCancelled, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(120))
            // Muted mid-sentence: drop what was heard rather than answering
            // half a question the user decided not to finish asking.
            if isMuted { _ = dictation.stop(); return nil }

            let current = dictation.transcript
            if current != lastTranscript {
                lastTranscript = current
                heard = current
            }

            if dictation.level > Self.voiceLevel { lastVoiceAt = ContinuousClock.now }
            // Only after the caller has actually said something, and then gone
            // quiet for the full grace period.
            if let voiced = lastVoiceAt, ContinuousClock.now - voiced > Self.silenceGrace {
                break
            }
        }

        let question = await dictation.finish()
        return question.isEmpty ? nil : question
    }

    private func answerQuestion(_ question: String) async {
        phase = .thinking
        heard = question

        // Streaming first: sentence audio starts while the model is still
        // writing. Any failure before audio starts falls through to the
        // blocking path, so a broken socket costs latency, never an answer.
        if await streamAnswer(question) { return }
        guard !Task.isCancelled else { return }

        do {
            let spoken = try await service.ask(question: question)
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
    private func streamAnswer(_ question: String) async -> Bool {
        if stream == nil { stream = service.voiceStream() }
        guard let stream else { return false }

        var text = ""
        var audioStarted = false
        var ttsLost = false

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
                    answer = text
                case .reset:
                    // What streamed so far was agent scaffolding, not answer.
                    text = ""
                    answer = ""
                case .audioBegin(let sampleRate, let channels, _, let isFiller):
                    try streamPlayer.begin(sampleRate: sampleRate, channels: channels)
                    // A thinking cue is not the answer: if the turn fails
                    // after only the cue played, the fallback must still run,
                    // or the caller gets "Let me check." and then nothing.
                    if !isFiller { audioStarted = true }
                    phase = .speaking
                case .audioChunk(let chunk):
                    streamPlayer.enqueue(chunk)
                case .audioEnd:
                    break
                case .ttsUnavailable:
                    ttsLost = true
                case .done(let spoken, let source):
                    let final = spoken.isEmpty ? text : spoken
                    answer = final
                    exchanges.insert(
                        VoiceExchange(question: question, answer: final, source: source),
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

    /// Speaks and waits for playback to finish, so the next turn does not start
    /// listening while the assistant is still talking — otherwise it hears
    /// itself and answers its own answer.
    private func speak(_ spoken: SpokenAnswer) async {
        phase = .speaking
        answer = spoken.text

        await withCheckedContinuation { continuation in
            player.play(spoken) { continuation.resume() }
        }
    }

    private static let greeting = "ATARU here. What would you like to know?"

    private static func failureLine(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription
            ?? "Something went wrong reaching your vault."
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
