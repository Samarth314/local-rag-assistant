import Foundation

/// Listens for "Hey ATARU" while the app is on screen, catches the question
/// asked in the same breath as the phrase, and then gets out of the way.
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

    /// Called on the main actor once the phrase - and whatever was said after
    /// it in the same breath - has been heard. The microphone is already closed
    /// by then: whatever runs the turn is free to open its own without fighting
    /// this one for the audio engine.
    ///
    /// The payload is the command that followed the phrase without a pause
    /// ("hey ataru CHECK THE TIME"), and it is `nil` when the speaker stopped
    /// at the name. Those are two different turns: a command is already a
    /// question and gets asked immediately, while a bare name needs the cue and
    /// a fresh listening turn. See `VoiceViewModel.beginWakeTurn`.
    var onWake: ((String?) -> Void)?

    /// How long one recognition session runs before it is cycled. Apple's own
    /// per-task ceiling is about a minute and `SpeechDictation` re-arms across
    /// it; this is the outer loop, comfortably inside that.
    ///
    /// It is DEFERRED while a command is being captured - see `watchSession`.
    static let restartAfter: Duration = .seconds(50)

    /// How often the accumulated transcript is checked. Fast enough that the
    /// phrase and the reply feel connected, slow enough to be free.
    static let pollInterval: Duration = .milliseconds(150)

    /// No new words AND a quiet microphone for this long ends the command that
    /// followed the phrase. Deliberately the same number as
    /// `CallSessionModel.silenceGrace`, which is the one this fleet has tuned
    /// against real speech; it is repeated rather than imported because nothing
    /// else in `Core` knows a call exists.
    static let commandSilence: Duration = .milliseconds(1600)

    /// Mirrors `CallSessionModel.voiceLevel`, for the same reason.
    static let voiceLevel: Double = 0.12

    /// The longest a same-breath command is read for before it is asked
    /// regardless. A room with a television in it never goes quiet, so silence
    /// alone is not a guaranteed terminator.
    static let captureCeiling: Duration = .seconds(12)

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
        // Apple's recogniser has never seen this word, so tell it to expect it.
        // Without this the standby stream is scanning transcripts that were
        // written by an engine actively biased AWAY from the only word that
        // matters here - which is most of why the phrase "sometimes doesn't
        // register at all".
        dictation.contextualBias = WakePhrase.contextualStrings
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
            let outcome = await watchSession()

            // Closed BEFORE the callback, always: the turn that follows opens
            // its own audio engine, and two engines tapping the same input is
            // how a wake word turns into a microphone that hears nothing.
            dictation.cancel()

            if case .woke(let command) = outcome {
                // Nilled and paused BEFORE the callback, so a second match
                // cannot arrive on top of the turn this one is about to start.
                watcher = nil
                status = .paused
                onWake?(command.isEmpty ? nil : command)
                return
            }
            // Otherwise the session simply aged out; loop round and open a
            // fresh one. Nothing is announced, because nothing happened.
        }
        watcher = nil
    }

    /// How one standby session ended.
    private enum Outcome {
        /// It aged out, or the engine died. Nothing happened.
        case none
        /// The phrase was heard. The payload is whatever was said after it in
        /// the same breath - empty when the speaker stopped at the name.
        case woke(String)
    }

    /// Watches one recognition stream until the phrase arrives, and then KEEPS
    /// WATCHING THE SAME STREAM for the command that follows it.
    ///
    /// ## Why the stream is not torn down at the phrase
    ///
    /// It used to be: match, cancel, hand off, and let the turn open a fresh
    /// recogniser. That is correct for "hey ATARU" *pause* "check the time",
    /// and it silently loses the far more natural "hey ataru check the time" -
    /// the command is spoken into the teardown, while one engine is closing and
    /// the next has not opened, so the words exist in no transcript at all.
    /// Every field report of "it only works if I pause" is this gap.
    ///
    /// So the phrase is now a POSITION in a transcript that keeps growing, not
    /// an event that ends the session. Text arriving after that position is the
    /// command, and the session is only torn down once the speaker is finished.
    private func watchSession() async -> Outcome {
        let cycleEnds = ContinuousClock.now + Self.restartAfter
        // Non-nil once the phrase has landed. From then on the only question
        // is where the command ends.
        var captureStartedAt: ContinuousClock.Instant?
        var lastActivityAt = ContinuousClock.now
        var command = ""

        while !Task.isCancelled {
            // THE CYCLE TIMER IS DEFERRED WHILE A CAPTURE IS RUNNING. Cycling
            // the session restarts `SpeechDictation`, which drops the
            // accumulated transcript - and mid-command that transcript IS the
            // question. A capture has its own, much shorter, ceiling.
            if captureStartedAt == nil, ContinuousClock.now >= cycleEnds { return .none }

            try? await Task.sleep(for: Self.pollInterval)
            guard !Task.isCancelled else { return .none }

            // The recogniser stopping is not the same as the session ending -
            // `SpeechDictation` re-arms itself - but an engine that has
            // genuinely died reports `isRecording == false` and will never
            // produce another word.
            let recording = dictation.isRecording

            if let capture = WakePhrase.capture(in: dictation.transcript) {
                if captureStartedAt == nil {
                    captureStartedAt = ContinuousClock.now
                    lastActivityAt = ContinuousClock.now
                }
                // Partials are revised as well as extended, so this is a
                // comparison rather than an append; a revision is activity too.
                if capture.command != command {
                    command = capture.command
                    lastActivityAt = ContinuousClock.now
                }
            }

            guard let startedAt = captureStartedAt else {
                // Still scanning. A dead engine here is just a cycle.
                if !recording { return .none }
                continue
            }

            // A dead engine DURING a capture is not a cycle - whatever was
            // heard is still a question, and throwing it away to open a fresh
            // recogniser is the bug this method exists to fix.
            if !recording { return .woke(command) }

            // The end of the command is judged on two things at once, because
            // each alone has a known failure: a stalled recogniser reads as
            // silence (the truncated questions `CallSessionModel` documents),
            // and a noisy room never falls below the level threshold.
            if dictation.level > Self.voiceLevel { lastActivityAt = ContinuousClock.now }
            if ContinuousClock.now - lastActivityAt > Self.commandSilence {
                return .woke(command)
            }
            if ContinuousClock.now - startedAt > Self.captureCeiling {
                return .woke(command)
            }
        }
        return .none
    }
}

/// Where the wake phrase sits in a transcript, and what was said after it.
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

    /// What the recogniser is TOLD to expect, as opposed to what it is
    /// forgiven for producing. `SFSpeechRecognitionRequest.contextualStrings`
    /// weights these up, which is the cheap half of the recognition-rate fix -
    /// the alias list below is the half that catches what still comes out
    /// wrong.
    static let contextualStrings = ["ATARU", "Hey ATARU"]

    /// Everything that counts as the name, already normalised.
    ///
    /// The bar for adding one (2026-08-29): it has to be something an English
    /// recogniser actually writes down for this name, AND it has to be a thing
    /// nobody says by accident, because a false wake opens the microphone in
    /// the middle of a conversation nobody meant to have with a phone.
    ///
    /// Rejected on that second test, all of them real mis-hearings: "a tattoo",
    /// "a true", "a tour", "ottawa". Every one of them is ordinary English that
    /// Arya could say in a room with the phone on the table.
    static let variants = [
        "ataru", "a taru", "at aru", "atarou", "otaru", "attaru",
        "atari", "a tari", "a tarot", "ah taru",
        // Added 2026-08-29, after the phrase was reported as intermittent on a
        // real device. Vowel endings first ("ataru" has no English anchor, so
        // the last vowel is what the recogniser guesses at), then the "hey"
        // swallowing the leading "a" - "hey ataru" said quickly gives up the
        // "a" to the preceding word and lands as a bare "taru", which is not a
        // word in English and so is safe on its own.
        "taru", "a taro", "ataro", "atara", "a tarou",
    ]

    /// `variants`, split into words once and longest first so a two-word alias
    /// wins over a one-word one starting inside it.
    private static let variantWords: [[String]] = variants
        .map { $0.split(separator: " ").map(String.init) }
        .sorted { $0.count > $1.count }

    /// One word of a transcript: what it normalises to, and where it starts in
    /// the ORIGINAL string - which is what lets the command be handed on in the
    /// speaker's own words rather than in normalised form.
    struct Token: Equatable {
        let text: String
        let start: String.Index
    }

    /// Where the phrase was found, as a half-open range of token indices.
    struct Match: Equatable {
        let start: Int
        /// One past the last token of the phrase - i.e. where the command
        /// begins, if there is one.
        let end: Int
        /// The alias that matched, normalised. Useful in tests and in a log.
        let variant: String
    }

    /// The phrase and the same-breath command, in one pass over a transcript.
    struct Capture: Equatable {
        let match: Match
        /// Everything said after the phrase, exactly as the recogniser wrote
        /// it - casing and punctuation intact, because this string becomes the
        /// question. Empty when the phrase was the last thing said.
        let command: String
    }

    /// NO list of lead-ins ("hey", "ok", "hi"), deliberately. Matching the bare
    /// name already covers every one of them, because "hey ataru" contains
    /// "ataru" - and it also covers "ATARU, what's on my calendar", which is
    /// how the name actually gets used once the novelty wears off.
    static func heard(in transcript: String) -> Bool {
        find(in: transcript) != nil
    }

    static func find(in transcript: String) -> Match? {
        find(in: tokenize(transcript))
    }

    /// The phrase plus whatever trails it. `nil` means the phrase is not there
    /// at all; a `Capture` with an empty `command` means it is there and
    /// nothing has followed it yet.
    static func capture(in transcript: String) -> Capture? {
        let tokens = tokenize(transcript)
        guard let match = find(in: tokens) else { return nil }
        guard match.end < tokens.count else { return Capture(match: match, command: "") }
        let trailing = transcript[tokens[match.end].start...]
        return Capture(match: match,
                       command: trailing.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The FIRST occurrence, not the last: what follows the first mention of
    /// the name is what the speaker is asking for, and a second mention inside
    /// that is just part of the sentence.
    static func find(in tokens: [Token]) -> Match? {
        guard !tokens.isEmpty else { return nil }
        for start in tokens.indices {
            for words in variantWords where start + words.count <= tokens.count {
                var matched = true
                for offset in words.indices where tokens[start + offset].text != words[offset] {
                    matched = false
                    break
                }
                if matched {
                    return Match(start: start,
                                 end: start + words.count,
                                 variant: words.joined(separator: " "))
                }
            }
        }
        return nil
    }

    /// Splits a transcript into runs of letters and digits, lowercased, each
    /// remembering where it began. Matching whole tokens is what keeps "atari"
    /// out of "safari" - the padding trick the first version used said the same
    /// thing, less usefully, because it threw the positions away.
    static func tokenize(_ transcript: String) -> [Token] {
        var tokens: [Token] = []
        var index = transcript.startIndex
        while index < transcript.endIndex {
            guard transcript[index].isLetter || transcript[index].isNumber else {
                index = transcript.index(after: index)
                continue
            }
            let start = index
            while index < transcript.endIndex,
                  transcript[index].isLetter || transcript[index].isNumber {
                index = transcript.index(after: index)
            }
            tokens.append(Token(text: transcript[start..<index].lowercased(), start: start))
        }
        return tokens
    }

    /// Lowercased, punctuation reduced to spaces, runs of space collapsed -
    /// the same shape `Farewell.normalize` produces, and for the same reason.
    static func normalize(_ text: String) -> String {
        tokenize(text).map(\.text).joined(separator: " ")
    }
}
