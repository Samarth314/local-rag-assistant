import AVFoundation
import Foundation

/// Plays back a spoken answer.
///
/// Prefers the WAV the server rendered, because that is the same Piper voice
/// the telephone front door uses — the app and the phone line should not sound
/// like two different assistants. When no audio came back (the server has no
/// voice engine, or Demo mode), it falls back to `AVSpeechSynthesizer` so the
/// answer is still spoken rather than silently becoming text-only.
@MainActor
final class AnswerPlayer: NSObject, ObservableObject {

    @Published private(set) var isSpeaking = false

    /// Whether this player may configure and deactivate the shared audio
    /// session. True on the Ask tab, where nobody else owns audio. False
    /// during a call: there CallKit owns the session, and a player that sets
    /// `.playback` mid-call tears down the call's `.playAndRecord` route —
    /// which is what forced every answer onto the loudspeaker regardless of
    /// the speaker toggle.
    var managesAudioSession = true

    private var player: AVAudioPlayer?
    private let synthesizer = AVSpeechSynthesizer()
    private var completion: (() -> Void)?
    /// Whether this player is currently counted as a user of the shared audio
    /// session. Tracked so playback retains and releases exactly once.
    ///
    /// THE BUG THIS CLOSES: this player never retained `AudioSessionOwner` at
    /// all, so while it was speaking the holder count was zero - and
    /// `SpeechDictation`'s 5-second release timer, which checks nothing but
    /// that count, deactivated the session underneath it. That is the exact
    /// failure `AudioSessionOwner`'s header was written to kill, still fully
    /// reachable through the one player that had not been taught to retain.
    /// On a call it is reachable on the greeting, the goodbye and every error
    /// line, because those are the three things `speak(_:)` plays.
    private var sessionHeld = false
    /// When the synthesizer last started a word, for the pseudo-level below.
    private var lastWordAt = Date.distantPast
    /// The utterance currently being spoken, so a delegate callback arriving
    /// for a PREVIOUS one can be told apart from the current playback.
    ///
    /// `stopSpeaking(at: .immediate)` reports the cancellation asynchronously,
    /// so a `play` that replaces an in-flight answer sees the old utterance's
    /// `didCancel` land *after* the new one has already started - and an
    /// unguarded `finish()` there ends the new answer before its first word,
    /// invoking a completion that has not been earned. Identity is what
    /// separates the two.
    private var currentUtterance: AVSpeechUtterance?

    /// How loud the answer is right now, 0...1, for the orb.
    ///
    /// Real metering when playing server audio. The synthesizer offers no
    /// meter, so its level is a pulse that decays from each word boundary —
    /// synthetic, but tracking actual word cadence rather than faking a
    /// waveform from nothing.
    var level: Double {
        if let player, player.isPlaying {
            player.updateMeters()
            let db = Double(player.averagePower(forChannel: 0))
            return min(max(pow(10, db / 20), 0), 1)
        }
        if synthesizer.isSpeaking {
            let sinceWord = Date().timeIntervalSince(lastWordAt)
            return max(0.12, 0.55 * exp(-3 * sinceWord))
        }
        return 0
    }

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// Speaks `answer`, calling `onFinish` when playback ends for any reason —
    /// including failure, so a caller can always return the orb to idle.
    func play(_ answer: SpokenAnswer, onFinish: @escaping () -> Void) {
        stop()
        completion = onFinish
        // Retain for the whole of playback, whichever engine ends up doing it
        // and including the failure paths below - every one of them routes to
        // `finish()`, which is the single place the hold is given back.
        holdSession()

        guard let url = answer.audioURL, let data = try? Data(contentsOf: url), !data.isEmpty else {
            speakLocally(answer.text)
            return
        }

        do {
            try activateSession()
            let player = try AVAudioPlayer(data: data)
            player.delegate = self
            player.isMeteringEnabled = true
            self.player = player
            isSpeaking = true
            player.play()
        } catch {
            // Server audio that won't decode is still an answer worth hearing.
            speakLocally(answer.text)
        }
    }

    /// Stops playback and tells whoever was waiting that it is over.
    ///
    /// THE INVOCATION IS THE FIX. This used to set `completion = nil` without
    /// calling it, and `CallSessionModel.speak` waits on that block inside a
    /// `withCheckedContinuation`. So hanging up mid-answer - or any second
    /// `play` arriving over the first - stranded the continuation forever:
    /// `run()` never returned, and it holds the session model, the dictation
    /// engine and both players with it. `StreamingAnswerPlayer.resumeDrain`
    /// documents the same fix for the same defect; this mirrors it, including
    /// the nil-then-call order, because a continuation resumed twice traps.
    func stop() {
        player?.stop()
        player = nil
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        currentUtterance = nil
        isSpeaking = false
        releaseSession()
        let block = completion
        completion = nil
        block?()
    }

    private func holdSession() {
        guard !sessionHeld else { return }
        sessionHeld = true
        AudioSessionOwner.shared.retain()
    }

    /// Lets go of the shared session, once, whoever gets here first.
    ///
    /// Releasing rather than deactivating: if dictation or the streaming
    /// player still needs the session, the last user out is the one that
    /// deactivates it. That is the whole contract `AudioSessionOwner` exists
    /// to hold.
    private func releaseSession() {
        guard sessionHeld else { return }
        sessionHeld = false
        AudioSessionOwner.shared.release()
    }

    private func speakLocally(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            finish()
            return
        }
        do {
            try activateSession()
        } catch {
            finish()
            return
        }
        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.voice = Self.preferredVoice()
        // Slightly under default: these are answers read from documents, and
        // the default rate is tuned for short notifications.
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.95
        isSpeaking = true
        currentUtterance = utterance
        synthesizer.speak(utterance)
    }

    /// The closest iOS voice to the server's Piper `en_US-lessac-medium`.
    ///
    /// Enhanced/premium voices are only present once the user has downloaded
    /// them, so this picks the best installed voice rather than naming one and
    /// getting silence when it is absent.
    static func preferredVoice() -> AVSpeechSynthesisVoice? {
        let english = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en-US") }
        let byQuality = english.sorted { lhs, rhs in
            quality(lhs.quality) > quality(rhs.quality)
        }
        return byQuality.first ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    private static func quality(_ quality: AVSpeechSynthesisVoiceQuality) -> Int {
        switch quality {
        case .premium: return 3
        case .enhanced: return 2
        default: return 1
        }
    }

    private func activateSession() throws {
        guard managesAudioSession else { return }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try session.setActive(true)
        AudioSessionOwner.shared.markActive()
    }

    fileprivate func finish() {
        isSpeaking = false
        player = nil
        currentUtterance = nil
        let block = completion
        completion = nil
        // Through the owner rather than straight at the session: deactivating
        // here is what pulled the route out from under a call's next turn, and
        // the owner's linger is also what stops the following turn paying the
        // activation cost (and losing its first word inside it).
        releaseSession()
        block?()
    }
}

extension AnswerPlayer: AVAudioPlayerDelegate {
    // Both of these check that the callback belongs to the playback that is
    // running NOW. See `currentUtterance`: a late report from a superseded
    // answer would otherwise finish the one that replaced it.
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            guard player === self.player else { return }
            self.finish()
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in
            guard player === self.player else { return }
            self.finish()
        }
    }
}

extension AnswerPlayer: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       willSpeakRangeOfSpeechString characterRange: NSRange,
                                       utterance: AVSpeechUtterance) {
        Task { @MainActor in self.lastWordAt = Date() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            guard utterance === self.currentUtterance else { return }
            self.finish()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            guard utterance === self.currentUtterance else { return }
            self.finish()
        }
    }
}
