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

    private var service: ATARUService
    private var loop: Task<Void, Never>?

    init(service: ATARUService) {
        self.service = service
    }

    func update(service: ATARUService) {
        self.service = service
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
        phase = .idle
        heard = ""
    }

    // MARK: - The loop

    private func run() async {
        guard await dictation.requestAuthorization() else {
            phase = .failed(SpeechDictation.Failure.permissionDenied.localizedDescription)
            return
        }

        await speak(SpokenAnswer(text: Self.greeting, source: nil, audioURL: nil))

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
