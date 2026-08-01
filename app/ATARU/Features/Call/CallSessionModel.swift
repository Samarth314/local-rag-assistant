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

    @Published private(set) var phase: VoicePhase = .idle
    /// What the caller is saying right now.
    @Published private(set) var heard: String = ""
    /// The most recent answer, shown under the transcript.
    @Published private(set) var answer: String = ""
    @Published private(set) var exchanges: [VoiceExchange] = []

    let dictation = SpeechDictation()
    let player = AnswerPlayer()
    let streamPlayer = StreamingAnswerPlayer()

    private var service: ATARUService
    private var loop: Task<Void, Never>?
    /// The call's WebSocket to the server, opened on the first question and
    /// reused for every turn after. Nil until needed, nil again after a
    /// failure so the next turn reconnects fresh.
    private var stream: VoiceStreamSession?

    init(service: ATARUService) {
        self.service = service
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

        // Greet in the server's voice when it has one, so the call opens
        // sounding like the assistant that will answer. Any failure falls
        // back to the phone's voice - the call must greet regardless.
        let greeting = (try? await service.greeting())
            ?? SpokenAnswer(text: Self.greeting, source: nil, audioURL: nil)
        await speak(greeting)

        while !Task.isCancelled {
            guard let question = await listenForOneTurn() else { break }
            guard !Task.isCancelled else { break }
            await answerQuestion(question)
        }
    }

    /// Records until the caller stops talking. Returns nil if the turn produced
    /// nothing, which ends the loop rather than spinning on an empty mic.
    private func listenForOneTurn() async -> String? {
        do {
            try dictation.start()
        } catch {
            phase = .failed(error.localizedDescription)
            return nil
        }

        phase = .listening
        heard = ""

        var lastTranscript = ""
        var quietSince = ContinuousClock.now
        // Give the caller a moment to start before silence counts against them.
        let deadline = ContinuousClock.now + .seconds(20)

        while !Task.isCancelled, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(120))

            let current = dictation.transcript
            if current != lastTranscript {
                lastTranscript = current
                heard = current
                quietSince = ContinuousClock.now
            } else if !current.isEmpty, ContinuousClock.now - quietSince > Self.silenceGrace {
                break
            }
        }

        let question = dictation.stop()
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
                case .audioBegin(let sampleRate, let channels, _):
                    try streamPlayer.begin(sampleRate: sampleRate, channels: channels)
                    audioStarted = true
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
