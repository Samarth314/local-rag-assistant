import Foundation

/// How sure the server's recogniser was about the transcript it just returned.
///
/// Every field is optional and the whole object may be missing, and those are
/// three different answers that must not be collapsed into one:
///
///  - the object is absent -> this server does not report confidence at all
///  - a field is null -> it reports confidence, but could not measure this
///  - a field has a value -> that is the measurement
///
/// So nothing here is defaulted. `low_confidence` in particular is a `Bool?`
/// rather than a `Bool`, because "not measured" must never render as "measured
/// and fine" - the whole point of the flag is that the server can ask "did you
/// say X?" when it is true, and a false it invented is a question never asked.
struct STTConfidence: Equatable, Sendable {
    let avgLogprob: Double?
    let minLogprob: Double?
    let lowConfidence: Bool?

    init(avgLogprob: Double? = nil, minLogprob: Double? = nil, lowConfidence: Bool? = nil) {
        self.avgLogprob = avgLogprob
        self.minLogprob = minLogprob
        self.lowConfidence = lowConfidence
    }

    /// True only when the server SAID so. See the note above.
    var isLowConfidence: Bool { lowConfidence == true }

    /// The wire object, with unmeasured fields left out rather than sent as
    /// null. Empty when there is nothing to say, which is what callers use to
    /// decide not to attach it at all.
    var jsonObject: [String: Any] {
        var object: [String: Any] = [:]
        if let avgLogprob { object["avg_logprob"] = avgLogprob }
        if let minLogprob { object["min_logprob"] = minLogprob }
        if let lowConfidence { object["low_confidence"] = lowConfidence }
        return object
    }
}

extension STTConfidence: Codable {
    enum CodingKeys: String, CodingKey {
        case avgLogprob = "avg_logprob"
        case minLogprob = "min_logprob"
        case lowConfidence = "low_confidence"
    }
}

/// A finished transcript and whatever the server was able to say about it.
///
/// `confidence` is nil on every path that did not come from the server's own
/// recogniser - Apple's reports nothing of the kind, and a turn it answered
/// must not arrive looking measured.
struct Transcription: Equatable, Sendable {
    let text: String
    let confidence: STTConfidence?

    init(text: String, confidence: STTConfidence? = nil) {
        self.text = text
        self.confidence = confidence
    }
}

/// Transcription on ATARU's own hardware, biased toward the names it knows.
///
/// ## Why the model moved off the phone
///
/// WhisperKit on device was the right idea for the wrong reason. It is the
/// only engine that can be told a name is likely, and names are most of what
/// this assistant is asked about - but the model that does it is 632MB, and
/// measured on this phone it took 193 seconds to become usable on a cold
/// start, 67 after moving its encoder off the Neural Engine. iOS offers no
/// way to keep it resident: a backgrounded app of that size is exactly what
/// gets terminated first, and every relaunch starts over. So a large share of
/// questions were still being answered by Apple's unbiased recogniser, which
/// is the failure the whole exercise existed to fix.
///
/// This is the shape the Claude and OpenAI apps use, and why they feel
/// instant: the device sends audio, the server owns the engine. Here that
/// server is the Orin, on Arya's own tailnet, running the same Whisper
/// large-v3-turbo with the same prompt biasing - and the roster is attached
/// there rather than sent from here, since the server is what knows it.
///
/// ## The privacy line is unchanged
///
/// The point was never that audio must never leave the device. It was that it
/// must never go to Apple's or anyone else's servers for transcription. It
/// goes to Arya's own machine, over his own network, and nowhere else -
/// which is where his questions were already going the moment they were
/// asked.
enum RemoteTranscriber {

    /// Transcribes 16 kHz mono samples, or returns nil to let the caller keep
    /// whatever it heard locally.
    ///
    /// Never throws: every failure here has a working fallback behind it, and
    /// a transcription path that can fail loudly on a call is worse than one
    /// that quietly hands back.
    static func transcribe(samples: [Float], endpoints: EndpointBuilder,
                           token: String?, timeout: Double = 12) async -> Transcription? {
        guard samples.count > 1_600, let url = endpoints.transcribe else {
            return nil          // under 0.1s of audio, or no server configured
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = wav(from: samples)
        request.timeoutInterval = timeout

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            // 503 is the server saying the engine is unreachable, which is a
            // real answer and not a transcript - the caller falls back.
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let payload = try? JSONDecoder().decode(Payload.self, from: data)
            else { return nil }
            let text = payload.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return Transcription(text: text, confidence: payload.stt) }
            // An empty transcript used to mean "ask someone else", so the turn
            // fell through to Apple's UNBIASED recogniser - in exactly the two
            // cases where that is the wrong move. If the server heard silence,
            // there is nothing for any engine to find. If the server REJECTED
            // a hallucination, a less careful engine will happily return the
            // same garbage. Both are real answers; report them as decided.
            if payload.silence == true || payload.rejected != nil {
                if let reason = payload.rejected {
                    sttLog.notice("server rejected the transcript (\(reason, privacy: .public)); not falling back")
                }
                // Decided empty, distinct from nil = "no answer".
                return Transcription(text: "", confidence: payload.stt)
            }
            return nil
        } catch {
            return nil
        }
    }

    /// Internal rather than private so the wire contract can be pinned by a
    /// test - the shape is the Python side's, and it is what breaks silently.
    struct Payload: Decodable {
        let text: String
        let engine: String?
        let biased: Bool?
        let latency_ms: Double?
        /// The Orin never decoded: the audio had no speech in it.
        let silence: Bool?
        /// It decoded and the server THREW THE RESULT AWAY - a prompt echo or
        /// a repetition loop. Distinct from silence, and the distinction is
        /// what stops the phone reaching for a worse recogniser.
        let rejected: String?
        /// How sure the decode was, when this server measures it. Absent on
        /// every server that does not, which is why it is optional all the
        /// way down - see `STTConfidence`.
        let stt: STTConfidence?
    }

    /// A 16 kHz mono PCM16 WAV around the captured samples.
    ///
    /// PCM16 rather than float: it halves what goes over the wire for no
    /// audible difference at this sample rate, and it is what every server
    /// side WAV reader expects without special-casing.
    private static func wav(from samples: [Float]) -> Data {
        let rate: UInt32 = 16_000
        let payload = samples.count * 2
        var data = Data(capacity: 44 + payload)

        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + payload))
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))              // PCM header length
        append(UInt16(1))               // format: PCM
        append(UInt16(1))               // channels: mono
        append(rate)
        append(rate * 2)                // byte rate: rate * channels * 2
        append(UInt16(2))               // block align
        append(UInt16(16))              // bits per sample
        data.append(contentsOf: Array("data".utf8))
        append(UInt32(payload))

        for sample in samples {
            // Clamped before scaling: a sample slightly outside -1...1 (which
            // the converter does produce) would otherwise wrap to full-scale
            // noise of the opposite sign.
            let clamped = max(-1, min(1, sample))
            append(Int16(clamped * 32_767))
        }
        return data
    }
}
