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
    /// When the synthesizer last started a word, for the pseudo-level below.
    private var lastWordAt = Date.distantPast

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

    func stop() {
        player?.stop()
        player = nil
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        isSpeaking = false
        completion = nil
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
    }

    fileprivate func finish() {
        isSpeaking = false
        player = nil
        let block = completion
        completion = nil
        if managesAudioSession {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        block?()
    }
}

extension AnswerPlayer: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.finish() }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in self.finish() }
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
        Task { @MainActor in self.finish() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finish() }
    }
}
