import AVFoundation
import Foundation

/// Who currently needs the shared audio session, counted.
///
/// THE BUG THIS EXISTS FOR: `SpeechDictation.cleanUp()` armed a detached task
/// that slept 5 seconds and then deactivated `AVAudioSession`, guarded only by
/// `!isRecording && sessionActive`. It had no idea the answer was playing
/// through that same session. Back when the Ask screen used the blocking
/// player, audio arrived long after the release had already fired and nobody
/// noticed. Since the answer started streaming, playback begins around T+3.3s
/// - and the release lands at T+5.0s, in the middle of the sentence.
///
/// Arya's report was "talked out loud up till connor and then went quiet",
/// on an answer whose audio is 3.4 seconds long. The session was pulled out
/// from under the player mid-utterance.
///
/// The rule is simply that deactivation is a decision for the LAST user of the
/// session, not for whoever happens to finish first: every user retains while
/// it needs audio, only the drop to zero schedules a release, and any retain
/// cancels a release that has not fired yet.
@MainActor
final class AudioSessionOwner {
    static let shared = AudioSessionOwner()

    /// How long the session is held after the last user lets go. Keeping it
    /// briefly is deliberate - reactivating costs time and the first word of
    /// the next turn is lost inside it (that was its own bug, 2026-08-03).
    static let lingerSeconds: Double = 5

    private var holders = 0
    private var release: Task<Void, Never>?
    private(set) var isActive = false

    /// True while anything is playing or recording - so a caller that still
    /// wants the old cheap guard can ask instead of assuming.
    var inUse: Bool { holders > 0 }

    func retain() {
        holders += 1
        release?.cancel()
        release = nil
    }

    func release(after linger: Double = AudioSessionOwner.lingerSeconds) {
        holders = max(0, holders - 1)
        guard holders == 0 else { return }
        release?.cancel()
        release = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(linger))
            guard let self, !Task.isCancelled, self.holders == 0 else { return }
            self.isActive = false
            // Failing here is not worth surfacing: whatever the user asked for
            // has already succeeded or failed by now.
            try? AVAudioSession.sharedInstance()
                .setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    /// Marks the session live. Callers still configure and activate it
    /// themselves; this only records that it is up so the release path knows.
    func markActive() {
        isActive = true
        release?.cancel()
        release = nil
    }

    /// Everything let go at once - used when a turn is torn down hard.
    func reset() {
        holders = 0
        release?.cancel()
        release = nil
    }
}
