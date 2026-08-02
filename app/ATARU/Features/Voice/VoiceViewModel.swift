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

    let dictation = SpeechDictation()
    let player = AnswerPlayer()

    private var service: ATARUService
    private var askTask: Task<Void, Never>?

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
        case .speaking: return player.level
        default: return 0
        }
    }

    // MARK: - Listening

    func beginListening() async {
        guard phase.allowsNewQuestion else { return }
        guard await dictation.requestAuthorization() else {
            phase = .failed(SpeechDictation.Failure.permissionDenied.localizedDescription)
            return
        }
        if dictation.vocabulary.isEmpty,
           let names = try? await service.vocabulary(), !names.isEmpty {
            dictation.vocabulary = names
        }
        do {
            try dictation.start()
            partialTranscript = ""
            phase = .listening
            Haptics.fire(.tap)
        } catch let failure as SpeechDictation.Failure {
            phase = .failed(failure.localizedDescription)
            // On-device dictation missing is not a dead end: typing still works.
            if failure == .unavailable { isShowingTypeField = true }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func endListening() {
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

    /// Replays an earlier answer without asking again.
    func replay(_ exchange: VoiceExchange) {
        guard phase.allowsNewQuestion else { return }
        speak(SpokenAnswer(text: exchange.answer, source: exchange.source, audioURL: nil))
    }

    func stopSpeaking() {
        player.stop()
        phase = .idle
    }

    private func record(question: String, answer: SpokenAnswer) {
        exchanges.insert(
            VoiceExchange(question: question, answer: answer.text, source: answer.source),
            at: 0
        )
    }

    private func speak(_ answer: SpokenAnswer) {
        phase = .speaking
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
