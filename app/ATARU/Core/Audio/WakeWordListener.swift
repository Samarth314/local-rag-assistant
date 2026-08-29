import Foundation

/// Listens for "Hey ATARU" while the app is on screen, and gets out of the way
/// the moment it hears it.
///
/// ## What this is not
///
/// It is not "Hey Siri". There is no always-on hardware detector available to
/// a third-party app, and there is no honest way to run one in the background:
/// iOS gives a foreground app the microphone and takes it away again when the
/// app resigns active. So standby is FOREGROUND-ONLY on purpose - the
/// alternative is a `voip` background mode holding the microphone open behind
/// the user's back, which is precisely the behaviour a privacy-first assistant
/// should not have. Off screen, the way in is Siri (`AskATARUIntent`) or a
/// call.
///
/// ## Why it borrows `SpeechDictation`
///
/// Everything hard about running a continuous recogniser is already solved
/// there: on-device only (`requiresOnDeviceRecognition`, so no audio leaves the
/// phone), a persistent resampler, and - the part that matters most here -
/// `rearm()`, which starts a fresh recognition task whenever Apple ends the
/// current one at its ~1 minute ceiling.
///
/// This still restarts the whole session on `restartAfter` anyway, for the one
/// thing re-arming does not fix: `SpeechDictation` accumulates every task's
/// text into `settled`, so a transcript left running for an hour is an hour of
/// room noise held in memory and re-scanned on every poll. A cycled session
/// also recovers an engine that has wedged without reporting anything.
@MainActor
final class WakeWordListener: ObservableObject {

    enum Status: Equatable {
        case off
        /// The microphone is open and scanning for the phrase.
        case listening
        /// Standby is on, but something else owns the microphone right now -
        /// a turn, a call, or the app not being frontmost.
        case paused
        /// Standby cannot run at all, with the reason.
        case unavailable(String)

        var isListening: Bool { self == .listening }
    }

    @Published private(set) var status: Status = .off {
        didSet {
            guard status != oldValue else { return }
            onStatusChange?(status)
        }
    }

    /// Mirrored upward by whoever owns this, because SwiftUI does not observe
    /// an `ObservableObject` held inside another one - a view watching the
    /// view model would never redraw when this changed, and the toggle would
    /// go on showing "listening" over a recogniser that had died.
    var onStatusChange: ((Status) -> Void)?

    /// Called on the main actor the instant the phrase is heard. The
    /// microphone is already closed by then: whatever runs the turn is free to
    /// open its own without fighting this one for the audio engine.
    var onWake: (() -> Void)?

    /// How long one recognition session runs before it is cycled. Apple's own
    /// per-task ceiling is about a minute and `SpeechDictation` re-arms across
    /// it; this is the outer loop, comfortably inside that.
    static let restartAfter: Duration = .seconds(50)

    /// How often the accumulated transcript is checked. Fast enough that the
    /// phrase and the reply feel connected, slow enough to be free.
    static let pollInterval: Duration = .milliseconds(150)

    /// Whether standby is switched ON, which is not the same as whether the
    /// microphone is open right now. A pause keeps this true, so returning to
    /// the app resumes rather than requiring the toggle to be flipped again.
    private(set) var isEnabled = false

    private let dictation = SpeechDictation()
    private var watcher: Task<Void, Never>?

    init() {
        // A wake word needs neither word timings nor the recorded audio, and
        // both are pure cost on a session that runs for minutes at a time.
        dictation.tracksAudioDetail = false
    }

    // MARK: - Switching it on and off

    /// Turns standby on and opens the microphone.
    func enable() async {
        isEnabled = true
        await open()
    }

    /// Turns standby off. The toggle, and only the toggle.
    func disable() {
        isEnabled = false
        close()
        status = .off
    }

    /// Closes the microphone but stays armed - a turn is starting, a call came
    /// in, or the app is no longer frontmost.
    func pause() {
        guard isEnabled else { return }
        close()
        status = .paused
    }

    /// Re-opens after a pause. A no-op if standby is off or already listening.
    func resume() async {
        guard isEnabled else { return }
        await open()
    }

    // MARK: - The loop

    private func open() async {
        guard isEnabled, watcher == nil else { return }
        guard await SpeechDictation.requestAuthorization() else {
            status = .unavailable(
                SpeechDictation.Failure.permissionDenied.localizedDescription)
            isEnabled = false
            return
        }
        // The permission sheet is not instant, and standby can be switched off
        // while it is up.
        guard isEnabled, watcher == nil else { return }
        watcher = Task { @MainActor [weak self] in await self?.run() }
    }

    private func close() {
        watcher?.cancel()
        watcher = nil
        dictation.cancel()
    }

    private func run() async {
        while !Task.isCancelled, isEnabled {
            do {
                try dictation.start()
            } catch let failure as SpeechDictation.Failure {
                // On-device recognition missing is permanent for this locale,
                // so retrying is just a loop that burns battery saying no.
                status = .unavailable(failure.localizedDescription)
                isEnabled = false
                watcher = nil
                return
            } catch {
                status = .unavailable(error.localizedDescription)
                isEnabled = false
                watcher = nil
                return
            }

            status = .listening
            let cycleEnds = ContinuousClock.now + Self.restartAfter
            var heard = false

            while !Task.isCancelled, ContinuousClock.now < cycleEnds {
                try? await Task.sleep(for: Self.pollInterval)
                guard !Task.isCancelled else { break }
                // The recogniser stopping is not the same as the session
                // ending - `SpeechDictation` re-arms itself - but an engine
                // that has genuinely died reports `isRecording == false` and
                // will never produce another word. Cycle rather than spin.
                if !dictation.isRecording { break }
                if WakePhrase.heard(in: dictation.transcript) {
                    heard = true
                    break
                }
            }

            // Closed BEFORE the callback, always: the turn that follows opens
            // its own audio engine, and two engines tapping the same input is
            // how a wake word turns into a microphone that hears nothing.
            dictation.cancel()

            if heard {
                watcher = nil
                status = .paused
                onWake?()
                return
            }
            // Otherwise the session simply aged out; loop round and open a
            // fresh one. Nothing is announced, because nothing happened.
        }
        watcher = nil
    }
}

/// Whether a transcript contains the wake phrase.
///
/// Deliberately free of SwiftUI, `Speech` and the main actor, because it is the
/// whole of the feature's judgement and it should be testable as arithmetic.
///
/// The mis-hearings are not padding. Apple's recogniser has never seen the word
/// "ATARU" and reaches for the nearest thing it knows: "a taru" (two words),
/// "atari" (a word it very much does know), "otaru", "a tarot". Matching only
/// the spelling ATARU is spelled with would mean a wake word that works about
/// half the time, which is worse than not having one.
enum WakePhrase {

    /// Everything that counts as the name, already normalised.
    static let variants = [
        "ataru", "a taru", "at aru", "atarou", "otaru", "attaru",
        "atari", "a tari", "a tarot", "ah taru",
    ]

    /// NO list of lead-ins ("hey", "ok", "hi"), deliberately. Matching the bare
    /// name already covers every one of them, because "hey ataru" contains
    /// "ataru" - and it also covers "ATARU, what's on my calendar", which is
    /// how the name actually gets used once the novelty wears off.
    static func heard(in transcript: String) -> Bool {
        let normalized = normalize(transcript)
        guard !normalized.isEmpty else { return false }
        // Padded on both ends, so every match is on whole words AND the name
        // still counts when it is the first or last thing said: "atari" must
        // not be found inside "safari", and "hey ataru" with nothing after it
        // must still match.
        let padded = " \(normalized) "
        return variants.contains { padded.contains(" \($0) ") }
    }

    /// Lowercased, punctuation reduced to spaces, runs of space collapsed -
    /// the same shape `Farewell.normalize` produces, and for the same reason.
    static func normalize(_ text: String) -> String {
        let kept = text.lowercased().unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        return String(kept).split(separator: " ").joined(separator: " ")
    }
}
