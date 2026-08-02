import Foundation
import WhisperKit

/// On-device Whisper transcription, biased toward the names ATARU knows.
///
/// ## Why this exists at all
///
/// Apple's recogniser has no way to be told a word is likely. Asked on a call
/// for the last email from Saikat Chaudhuri it produced "psych", the mailbox
/// search found nothing, and the answer went downhill from there. Proper nouns
/// are the assistant's whole subject matter - people, projects, merchants - and
/// they are exactly what a general speech model has never seen.
///
/// WhisperKit accepts a *prompt*: text prepended to the decoder so the model
/// expects those tokens. Feeding it the people Arya actually corresponds with
/// turns an unknown surname into an expected one. That single capability is
/// why Whisper is here rather than the newer, otherwise-more-accurate Apple
/// engine, which offers no equivalent.
///
/// ## Shape
///
/// Loading pulls a CoreML model (hundreds of MB) on first run, so it happens
/// off the hot path and every caller degrades politely: until `isReady`, the
/// Apple recogniser's transcript stands. Audio never leaves the phone - the
/// model is local, and only the finished text is sent to ATARU.
actor WhisperTranscriber {

    /// What the engine is doing, for the Settings screen. Without this there
    /// is no way to tell a Whisper transcript from an Apple fallback, which
    /// made the first bad result impossible to diagnose from the outside.
    enum State: Equatable {
        case idle, loading, ready, failed(String)

        var label: String {
            switch self {
            case .idle: return "Not loaded"
            case .loading: return "Downloading model…"
            case .ready: return "Whisper (on-device, name-aware)"
            case .failed(let why): return "Apple dictation - Whisper unavailable (\(why))"
            }
        }
    }

    /// Readable from any actor; mirrors `state` for the UI.
    @MainActor static private(set) var uiState: State = .idle

    static let shared = WhisperTranscriber()

    /// large-v3-turbo: the accuracy of large-v3 at a fraction of the decode
    /// cost, which is what makes it usable on a phone between call turns.
    private static let modelName = "openai_whisper-large-v3-v20240930_turbo_632MB"

    private var kit: WhisperKit?
    private var loading: Task<WhisperKit?, Never>?
    private(set) var lastError: String?

    /// True once a model is resident and transcription will actually run.
    var isReady: Bool { kit != nil }

    /// Starts the download/load if it has not begun. Safe to call repeatedly.
    func prepare() {
        guard kit == nil, loading == nil else { return }
        Task { @MainActor in Self.uiState = .loading }
        loading = Task { [modelName = Self.modelName] in
            do {
                let config = WhisperKitConfig(model: modelName, download: true)
                return try await WhisperKit(config)
            } catch {
                return nil
            }
        }
        Task { await self.finishLoading() }
    }

    private func finishLoading() async {
        guard let loading else { return }
        let loaded = await loading.value
        self.kit = loaded
        self.loading = nil
        if loaded == nil { self.lastError = "WhisperKit model unavailable" }
        let resolved: State = loaded == nil ? .failed("download failed") : .ready
        await MainActor.run { Self.uiState = resolved }
    }

    /// Transcribes 16 kHz mono samples, biased toward `vocabulary`.
    ///
    /// Returns nil when no model is loaded or the audio yields nothing, so the
    /// caller keeps whatever Apple heard rather than losing the question.
    func transcribe(samples: [Float], vocabulary: [String]) async -> String? {
        guard let kit, samples.count > 1_600 else { return nil }   // <0.1s is not speech
        var options = DecodingOptions()
        options.language = "en"
        options.temperature = 0
        options.usePrefillPrompt = true
        options.withoutTimestamps = true
        // The biasing itself. Whisper reads the prompt as "text that came
        // just before", so a bare comma-separated roster is the shape that
        // works; tokens beyond the model's prompt window are dropped by
        // WhisperKit, hence the cap on how many names we send.
        if !vocabulary.isEmpty, let tokenizer = kit.tokenizer {
            let roster = vocabulary.prefix(60).joined(separator: ", ")
            let prompt = "Names and terms likely in this audio: \(roster)."
            let tokens = tokenizer.encode(text: " " + prompt)
                .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
            if !tokens.isEmpty { options.promptTokens = tokens }
        }
        do {
            let results = try await kit.transcribe(audioArray: samples, decodeOptions: options)
            let text = results.map(\.text).joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }
}
