import Foundation
import SwiftUI

/// Drives one recording, from the tap that starts it to the note it produces.
///
/// The same `SpeechDictation` the orb holds, used differently: the orb finishes
/// a turn and hands the text to the assistant, this finishes a recording and
/// hands the text to `NoteDigest`. Nothing here reaches the network except the
/// transcription itself, which is the app's normal recogniser and is the whole
/// of what "use the same text recognition" means.
///
/// Recording is a toggle, not a hold. A held button is right for a question —
/// it makes the end unambiguous and a release is a natural cancel — and wrong
/// for a note, which can run for minutes and should not require a thumb parked
/// on the glass for all of them.
@MainActor
final class NoteRecorder: ObservableObject {

    enum Phase: Equatable {
        case idle
        case recording
        case transcribing
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var startedAt: Date?
    /// Owned for this recorder's whole life and never swapped.
    let dictation = SpeechDictation()

    /// Live text, so something is on screen while the note is being spoken.
    var partial: String { dictation.transcript }
    var level: Double { dictation.level }

    var elapsed: TimeInterval {
        guard let startedAt else { return 0 }
        return Date().timeIntervalSince(startedAt)
    }

    func start() async {
        guard phase == .idle || phase.isFailure else { return }
        guard await dictation.requestAuthorization() else {
            phase = .failed(SpeechDictation.Failure.permissionDenied.localizedDescription)
            return
        }
        do {
            try dictation.start()
            startedAt = Date()
            phase = .recording
            Haptics.fire(.tap)
        } catch let failure as SpeechDictation.Failure {
            phase = .failed(failure.localizedDescription)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Stops, transcribes, and returns the finished note — or nil if nothing
    /// was said, which is a cancel rather than an error worth reporting.
    func finish() async -> Note? {
        guard phase == .recording else { return nil }
        let duration = elapsed
        phase = .transcribing
        let text = await dictation.finish()
        startedAt = nil

        guard let transcript = text.nilIfBlank else {
            phase = .failed(SpeechDictation.Failure.noSpeechDetected.localizedDescription)
            return nil
        }
        let note = Note(transcript: transcript, duration: duration)
        // A note with no bullets means the digest could not find a single
        // usable point — two words, or pure filler. Saving it would put an
        // empty card in the list.
        guard !note.digest.isEmpty else {
            phase = .failed("That was too short to make a note from.")
            return nil
        }
        phase = .idle
        Haptics.fire(.success)
        return note
    }

    func cancel() {
        dictation.cancel()
        startedAt = nil
        phase = .idle
    }
}

private extension NoteRecorder.Phase {
    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}
