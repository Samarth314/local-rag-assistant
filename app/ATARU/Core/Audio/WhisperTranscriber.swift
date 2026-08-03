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
        case preparing(String)        // on disk; loading + compiling for the ANE
        case ready
        case failed(String)

        var label: String {
            switch self {
            case .idle: return "Not loaded"
            case .downloading(let fraction):
                return "Downloading model… \(Int(fraction * 100))%"
            case .preparing(let stage):
                // The elapsed count is not decoration. This step said only
                // "Preparing model…" before, which is indistinguishable from
                // being wedged - and it genuinely runs for minutes, because
                // CoreML recompiles the encoder for the Neural Engine on
                // launches it fails to serve from its own cache.
                guard let seconds = WhisperTranscriber.shared.prepareElapsed else {
                    return "\(stage)…"
                }
                return String(format: "%@… %.0fs", stage, seconds)
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

    /// Where the model folder itself ends up under `modelStore`. Knowing this
    /// path is what lets a launch decide "already downloaded" without asking
    /// Hugging Face - see `prepare()`.
    private static var localModelFolder: URL {
        modelStore.appendingPathComponent(
            "models/argmaxinc/whisperkit-coreml/\(modelName)", isDirectory: true)
    }

    /// True when every model this variant needs is on disk with real weights.
    /// Checked rather than assumed: a download interrupted halfway leaves the
    /// folder present but useless, and silently loading that fails in a way
    /// that reads as "Whisper is broken".
    private static func isDownloaded(_ folder: URL) -> Bool {
        ["MelSpectrogram", "AudioEncoder", "TextDecoder"].allSatisfy { name in
            let weights = folder
                .appendingPathComponent("\(name).mlmodelc/weights/weight.bin")
            let size = try? FileManager.default
                .attributesOfItem(atPath: weights.path)[.size] as? Int
            return (size ?? 0) > 0
        }
    }

    private let lock = NSLock()
    private var kit: WhisperKit?
    private var isLoading = false
    private var isDecoding = false
    private var lastRun: Double?
    private var prepareStarted: Date?

    /// How long the current load has been running, so "preparing" can show its
    /// own age instead of looking identical whether it is 3 seconds or 300 in.
    var prepareElapsed: Double? {
        lock.lock(); defer { lock.unlock() }
        guard let started = prepareStarted else { return nil }
        return Date().timeIntervalSince(started)
    }

    /// True once a model is resident. Non-blocking by construction - see the
    /// type's note about the hang this replaced.
    var isReady: Bool {
        lock.lock(); defer { lock.unlock() }
        return kit != nil
    }

    /// Whether to carry the model on the phone at all.
    ///
    /// Off by default since the engine moved to the Orin (see
    /// `RemoteTranscriber`). What it buys is transcription away from the
    /// tailnet; what it costs is a minute of every cold start, during which
    /// dictation is Apple's and unbiased anyway - which is the wrong trade
    /// unless being off the network is the case being planned for.
    static let offlineKey = "ataru.offlineTranscription"

    static var offlineEnabled: Bool {
        UserDefaults.standard.bool(forKey: offlineKey)
    }

    /// Starts the download/load if it has not begun. Safe to call repeatedly.
    ///
    /// `retry` forces a second attempt over a load that has plainly stalled.
    /// Without it `isLoading` is a one-way latch: a detached load that wedges
    /// (or is suspended for long enough in the background) leaves the flag set
    /// forever, and every later call returns immediately having done nothing,
    /// so the app reports "preparing" for the rest of its life with no way out.
    func prepare(retry: Bool = false) {
        guard Self.offlineEnabled || retry else { return }
        lock.lock()
        if retry, isLoading, let started = prepareStarted,
           Date().timeIntervalSince(started) > 120 {
            isLoading = false
        }
        guard kit == nil, !isLoading else { lock.unlock(); return }
        isLoading = true
        prepareStarted = Date()
        lock.unlock()

        // Detached on purpose: this must not run on any caller's executor, or
        // it blocks whatever asked it to start. userInitiated, not utility -
        // this is the engine the next thing the user says depends on, and
        // utility work is the first thing iOS throttles under Low Power Mode.
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            var loaded: WhisperKit?
            var failure = "download failed"
            var route = "download"
            let started = Date()
            do {
                let store = Self.modelStore
                let local = Self.localModelFolder
                let folder: URL
                if Self.isDownloaded(local) {
                    // The whole model is already here, so do not go near the
                    // network. `WhisperKit.download` asks Hugging Face for the
                    // file list on every call even when nothing needs fetching:
                    // offline that throws and reads as "Whisper unavailable",
                    // and on a slow connection it stalls the load behind a
                    // request whose answer is already known.
                    route = "cached"
                    folder = local
                    await MainActor.run { Self.uiState = .preparing("Loading model") }
                } else {
                    await MainActor.run { Self.uiState = .downloading(0) }
                    // Downloading explicitly (rather than letting init do it) is
                    // what makes a percentage possible - otherwise the UI can only
                    // say "downloading" for several silent minutes.
                    folder = try await WhisperKit.download(
                        variant: Self.modelName, downloadBase: store,
                        useBackgroundSession: false
                    ) { progress in
                        let fraction = progress.fractionCompleted
                        Task { @MainActor in Self.uiState = .downloading(fraction) }
                    }
                    await MainActor.run { Self.uiState = .preparing("Preparing model") }
                }
                // prewarm is deliberately off. It compiles each model and
                // throws the result away to cap peak memory, and `load` then
                // does the same work again - two full passes over a 632MB
                // model on every launch. CoreML's Neural Engine cache does not
                // reliably serve these models across launches (a fresh
                // compiled bundle appears in the app's cache almost every
                // time), so that second pass is not free: it is minutes, and
                // dictation silently falls back to Apple for all of them.
                // The audio encoder runs on the GPU, not the Neural Engine.
                //
                // Measured: the cached single-pass load took 193 seconds, and
                // nearly all of it is CoreML compiling the 402MB encoder for
                // the ANE - work it redoes on almost every launch, because its
                // own cache does not serve these models reliably across
                // processes. Three minutes of every launch with the engine
                // unavailable is a worse trade than a slower decode, and the
                // GPU path needs no such compilation. The decoder stays on the
                // ANE: it is 194MB and it is the part that runs per token.
                //
                // This costs nothing in accuracy. Same model, same weights,
                // different silicon. If turns feel slow, Settings shows the
                // last transcription time and that is the number to judge on.
                let config = WhisperKitConfig(model: Self.modelName,
                                              downloadBase: store,
                                              modelFolder: folder.path,
                                              computeOptions: ModelComputeOptions(
                                                  audioEncoderCompute: .cpuAndGPU),
                                              prewarm: false, load: true, download: false)
                loaded = try await WhisperKit(config)
            } catch {
                failure = error.localizedDescription
            }
            self.lock.lock()
            self.kit = loaded
            self.isLoading = false
            if loaded != nil { self.prepareStarted = nil }
            self.lock.unlock()
            let resolved: State = loaded == nil ? .failed(failure) : .ready
            await MainActor.run { Self.uiState = resolved }
            Self.record("\(route) \(loaded == nil ? "FAILED \(failure)" : "ok") "
                        + String(format: "%.1fs", Date().timeIntervalSince(started)))
            if loaded != nil { Self.discardStaleModels() }
        }
    }

    /// One line per load attempt in the app container, because the thing worth
    /// knowing about this path - how long it takes, and whether it took the
    /// cached route - is invisible from outside the phone otherwise.
    private static func record(_ line: String) {
        let log = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("whisper-load.log")
        let stamp = ISO8601DateFormatter().string(from: Date())
        guard let data = "\(stamp) \(line)\n".data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: log) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: log)
        }
    }

    /// Deletes the copy of the model left behind in Documents by builds that
    /// predated `downloadBase`. It is over a gigabyte of the user's storage
    /// that nothing reads, and it is only safe to remove once the copy we do
    /// read has loaded - which is why this runs after a successful load.
    private static func discardStaleModels() {
        let stale = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("huggingface", isDirectory: true)
        guard FileManager.default.fileExists(atPath: stale.path) else { return }
        try? FileManager.default.removeItem(at: stale)
        record("removed stale Documents/huggingface model copy")
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
