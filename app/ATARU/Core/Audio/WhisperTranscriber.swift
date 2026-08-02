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
/// ## Why this is a lock and not an actor
///
/// It was an actor, and the app hung on "Thinking" forever. Loading was
/// started with `Task { ... }` from inside an actor method, which INHERITS the
/// actor's isolation - so WhisperKit's model load (hundreds of MB, compiled
/// for the Neural Engine) occupied the actor for as long as it took, and the
/// `isReady` check every question makes had to queue behind it. The fallback
/// that was supposed to make loading invisible could never run.
///
/// Loading is now a detached task and state lives behind a lock, so asking
/// "is it ready" is always answerable immediately, whatever the model is
/// doing. Audio never leaves the phone either way: the model is local, and
/// only the finished text is sent to ATARU.
final class WhisperTranscriber: @unchecked Sendable {

    /// What the engine is doing, for the Settings screen. Without this a
    /// Whisper transcript and an Apple fallback are indistinguishable from
    /// outside, which is what made the first bad result so hard to place.
    enum State: Equatable {
        case idle
        case downloading(Double)      // 0...1
        case preparing                // downloaded; compiling for the ANE
        case ready
        case failed(String)

        var label: String {
            switch self {
            case .idle: return "Not loaded"
            case .downloading(let fraction):
                return "Downloading model… \(Int(fraction * 100))%"
            case .preparing: return "Preparing model…"
            case .ready:
                if let seconds = WhisperTranscriber.shared.lastRunSeconds {
                    return String(format: "Whisper (on-device, name-aware) - last %.1fs", seconds)
                }
                return "Whisper (on-device, name-aware)"
            case .failed(let why): return "Apple dictation - Whisper unavailable (\(why))"
            }
        }
    }

    @MainActor static private(set) var uiState: State = .idle

    static let shared = WhisperTranscriber()

    /// large-v3-turbo: the accuracy of large-v3 at a fraction of the decode
    /// cost, which is what makes it usable on a phone between call turns.
    private static let modelName = "openai_whisper-large-v3-v20240930_turbo_632MB"

    /// Where the model lives. Application Support survives app reinstalls, so
    /// a rebuild does not re-download 632MB - the old default put it somewhere
    /// that did not obviously persist, and every install started over.
    private static var modelStore: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
            .appendingPathComponent("WhisperKitModels", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private let lock = NSLock()
    private var kit: WhisperKit?
    private var isLoading = false
    private var isDecoding = false
    private var lastRun: Double?

    /// True once a model is resident. Non-blocking by construction - see the
    /// type's note about the hang this replaced.
    var isReady: Bool {
        lock.lock(); defer { lock.unlock() }
        return kit != nil
    }

    /// Starts the download/load if it has not begun. Safe to call repeatedly.
    func prepare() {
        lock.lock()
        guard kit == nil, !isLoading else { lock.unlock(); return }
        isLoading = true
        lock.unlock()

        Task { @MainActor in Self.uiState = .downloading(0) }
        // Detached on purpose: this must not run on any caller's executor, or
        // it blocks whatever asked it to start.
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            var loaded: WhisperKit?
            var failure = "download failed"
            do {
                let store = Self.modelStore
                // Downloading explicitly (rather than letting init do it) is
                // what makes a percentage possible - otherwise the UI can only
                // say "downloading" for several silent minutes.
                let folder = try await WhisperKit.download(
                    variant: Self.modelName, downloadBase: store,
                    useBackgroundSession: false
                ) { progress in
                    let fraction = progress.fractionCompleted
                    Task { @MainActor in Self.uiState = .downloading(fraction) }
                }
                await MainActor.run { Self.uiState = .preparing }
                // prewarm: compile into the Neural Engine now. Skipping it
                // moves that cost onto the user's first question, which reads
                // as the app hanging.
                let config = WhisperKitConfig(model: Self.modelName,
                                              downloadBase: store,
                                              modelFolder: folder.path,
                                              prewarm: true, load: true, download: false)
                loaded = try await WhisperKit(config)
            } catch {
                failure = error.localizedDescription
            }
            self.lock.lock()
            self.kit = loaded
            self.isLoading = false
            self.lock.unlock()
            let resolved: State = loaded == nil ? .failed(failure) : .ready
            await MainActor.run { Self.uiState = resolved }
        }
    }

    /// How long the last transcription took, so latency is visible instead of
    /// guessed at.
    var lastRunSeconds: Double? {
        lock.lock(); defer { lock.unlock() }
        return lastRun
    }

    /// Transcription with a hard ceiling that actually holds.
    ///
    /// The previous attempt raced `transcribe` against a sleep inside a task
    /// group - which does nothing, because a task group awaits every child
    /// before it returns and WhisperKit's inference never checks
    /// cancellation. The deadline passed and the app kept waiting anyway.
    /// Here the work runs detached and the continuation resumes on whichever
    /// finishes first; a slow decode is simply abandoned to finish unheard.
    func transcribe(samples: [Float], vocabulary: [String],
                    timeout seconds: Double) async -> String? {
        final class Gate: @unchecked Sendable {
            private let lock = NSLock()
            private var done = false
            func claim() -> Bool {
                lock.lock(); defer { lock.unlock() }
                if done { return false }
                done = true
                return true
            }
        }
        let gate = Gate()
        return await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            Task.detached(priority: .userInitiated) { [weak self] in
                let text = await self?.transcribe(samples: samples, vocabulary: vocabulary)
                if gate.claim() { cont.resume(returning: text) }
            }
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                if gate.claim() { cont.resume(returning: nil) }
            }
        }
    }

    /// Transcribes 16 kHz mono samples, biased toward `vocabulary`.
    ///
    /// Returns nil when no model is loaded or the audio yields nothing, so the
    /// caller keeps whatever Apple heard rather than losing the question.
    func transcribe(samples: [Float], vocabulary: [String]) async -> String? {
        // One decode at a time - and that is a hard rule, not tidiness. A
        // timed-out decode is ABANDONED, not stopped: it keeps running on the
        // Neural Engine. Starting a second decode on the same WhisperKit
        // instance while it grinds means two inferences sharing one decoder
        // state - they slow each other until every turn overruns, so one bad
        // turn poisoned the whole session. If the engine is busy, this turn
        // simply keeps Apple's transcript.
        lock.lock()
        guard let kit = self.kit, !isDecoding, samples.count > 1_600 else {
            lock.unlock()
            return nil   // no model, engine busy, or <0.1s of audio
        }
        isDecoding = true
        lock.unlock()
        defer { lock.lock(); isDecoding = false; lock.unlock() }

        var options = DecodingOptions()
        options.language = "en"
        options.temperature = 0
        options.usePrefillPrompt = true
        options.withoutTimestamps = true
        // The biasing itself. Whisper reads the prompt as "text that came
        // just before" - it is context, not an instruction. So the prompt is
        // the bare comma-separated roster and nothing else: a sentence like
        // "Names likely in this audio:" is prose the model may happily
        // continue into the transcript.
        if !vocabulary.isEmpty, let tokenizer = kit.tokenizer {
            // Whisper reserves about half its 448-token context for the
            // prompt (~224 tokens). Budget by TOKENS, not by a name count: a
            // fixed cap of 16 names silently dropped the very people this
            // engine exists to hear (the roster is recency-ordered and ~200
            // long). ~192 tokens fits comfortably and covers ~50 names.
            let special = tokenizer.specialTokens.specialTokenBegin
            var tokens: [Int] = []
            for name in vocabulary {
                let piece = (tokens.isEmpty ? " " : ", ") + name
                let extra = tokenizer.encode(text: piece).filter { $0 < special }
                if tokens.count + extra.count > 192 { break }
                tokens.append(contentsOf: extra)
            }
            if !tokens.isEmpty { options.promptTokens = tokens }
        }
        let started = Date()
        do {
            let results = try await kit.transcribe(audioArray: samples, decodeOptions: options)
            let elapsed = Date().timeIntervalSince(started)
            lock.lock(); lastRun = elapsed; lock.unlock()
            let text = results.map(\.text).joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        } catch {
            return nil
        }
    }
}
