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
            // Only the notes path pays for word timings and a retained copy of
            // the audio. A question needs neither, and on a call - where a turn
            // ends every few seconds - they would be pure overhead.
            dictation.tracksAudioDetail = true
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

        // Snapshotted BEFORE anything else runs. Whatever else happens, the
        // words the user watched appear are the worst case, never nothing.
        let watched = dictation.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        // Local only: no upload, no server verdict, no ceiling to run past.
        // See SpeechDictation.finishLocally for why a note is not a question.
        let heard = await dictation.finishLocally()
        let text = heard.nilIfBlank ?? watched
        startedAt = nil

        guard let transcript = text.nilIfBlank else {
            phase = .failed(SpeechDictation.Failure.noSpeechDetected.localizedDescription)
            return nil
        }

        // Diarisation runs here, once, after the user has stopped talking -
        // never during the recording. It is nil for the ordinary case of one
        // person talking, which is the point: see SpeakerSplit.
        //
        // OFF THE MAIN ACTOR. One pass of squares over the whole capture is
        // milliseconds on a short note and not on a long one: the buffer is
        // 16 kHz mono floats, so about 4 MB per minute, and a twenty-minute
        // meeting is 80 MB of arithmetic between two frames. It needs nothing
        // from the main actor, so it does not run there.
        let words = dictation.timedWords
        let samples = dictation.lastCapture
        let turns = await Task.detached(priority: .userInitiated) {
            SpeakerSplit.turns(words: words, samples: samples)
        }.value
        let note = Note(transcript: transcript, duration: duration, turns: turns)
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
