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

    private var player: AVAudioPlayer?
    private let synthesizer = AVSpeechSynthesizer()
    private var completion: (() -> Void)?

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
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try session.setActive(true)
    }

    fileprivate func finish() {
        isSpeaking = false
        player = nil
        let block = completion
        completion = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
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
                                       didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finish() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finish() }
    }
}
