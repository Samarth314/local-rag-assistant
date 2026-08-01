import Foundation

/// One event from a streaming voice answer. See `voice_stream.py` for the
/// wire protocol; this is its client-side mirror.
enum VoiceStreamEvent: Sendable {
    case accepted
    case delta(String)
    /// Streamed text so far belonged to an agent tool turn; discard it.
    case reset
    case audioBegin(sampleRate: Double, channels: Int, sentence: String, isFiller: Bool)
    case audioChunk(Data)
    case audioEnd
    case ttsUnavailable
    case done(text: String, source: String?)
}

enum VoiceStreamError: Error {
    case notConnected
    case protocolViolation(String)
    case server(String)
    /// The socket went quiet past any plausible processing time. Treated like
    /// any other stream failure: fall back, reconnect next turn.
    case timedOut
}

/// A live WebSocket to `/voice/session`.
///
/// One session serves a whole call: the socket opens on the first question and
/// stays up, so later turns skip the connection handshake entirely. Ask one
/// question at a time — the server answers sequentially, and `ask` enforces
/// that by finishing its stream before the next call may begin.
///
/// This exists because the blocking `/voice/speak` round trip serialises
/// generation, synthesis and download; over this socket the first sentence is
/// audible while the model is still writing the rest. `/voice/speak` remains
/// the fallback whenever this path fails, so a broken socket can never make
/// the assistant mute.
final class VoiceStreamSession: @unchecked Sendable {

    private let url: URL
    private let token: String?
    private let session: URLSession
    private var task: URLSessionWebSocketTask?
    private let lock = NSLock()

    init?(baseURL: URL, token: String?) {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        switch components.scheme {
        case "http": components.scheme = "ws"
        case "https": components.scheme = "wss"
        default: return nil
        }
        let path = components.path.hasSuffix("/") ? components.path : components.path + "/"
        components.path = path + "voice/session"
        guard let url = components.url else { return nil }

        self.url = url
        self.token = token

        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = false
        config.urlCache = nil
        self.session = URLSession(configuration: config)
    }

    /// Sends a question and yields events until the server says `done`.
    ///
    /// The stream throws on transport failure or protocol violation, at which
    /// point the socket is dead — the caller should fall back to the blocking
    /// path for this question and let the next question reconnect.
    func ask(_ question: String) -> AsyncThrowingStream<VoiceStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let socket = try self.connectIfNeeded()
                    let payload = try JSONSerialization.data(
                        withJSONObject: ["type": "ask", "q": question])
                    try await socket.send(.string(String(decoding: payload, as: UTF8.self)))

                    var sawFirstEvent = false
                    while true {
                        // A healthy session is never silent for long: `accepted`
                        // lands immediately and long agent runs stream status
                        // heartbeats every couple of seconds. Silence beyond
                        // these windows means the stream is dead, not slow -
                        // without this, a lost ask leaves the call hanging in
                        // "thinking" forever.
                        let window: Duration = sawFirstEvent ? .seconds(60) : .seconds(15)
                        let message = try await Self.receive(from: socket, within: window)
                        sawFirstEvent = true
                        guard let event = try Self.parse(message) else { continue }
                        continuation.yield(event)
                        if case .done = event {
                            continuation.finish()
                            return
                        }
                    }
                } catch {
                    self.invalidate()
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func close() {
        invalidate()
    }

    // MARK: - Internals

    private func connectIfNeeded() throws -> URLSessionWebSocketTask {
        lock.lock()
        defer { lock.unlock() }
        if let task, task.state == .running || task.state == .suspended {
            if task.state == .suspended { task.resume() }
            return task
        }
        var request = URLRequest(url: url)
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let task = session.webSocketTask(with: request)
        task.resume()
        self.task = task
        return task
    }

    private func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    private static func receive(from socket: URLSessionWebSocketTask,
                                within window: Duration) async throws -> URLSessionWebSocketTask.Message {
        try await withThrowingTaskGroup(of: URLSessionWebSocketTask.Message?.self) { group in
            group.addTask { try await socket.receive() }
            group.addTask {
                try await Task.sleep(for: window)
                return nil
            }
            defer { group.cancelAll() }
            guard let first = try await group.next(), let message = first else {
                throw VoiceStreamError.timedOut
            }
            return message
        }
    }

    private static func parse(_ message: URLSessionWebSocketTask.Message) throws -> VoiceStreamEvent? {
        switch message {
        case .data(let data):
            return .audioChunk(data)
        case .string(let text):
            guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)),
                  let dict = object as? [String: Any],
                  let type = dict["type"] as? String else {
                throw VoiceStreamError.protocolViolation("unparseable frame")
            }
            switch type {
            case "accepted":
                return .accepted
            case "delta":
                return .delta(dict["text"] as? String ?? "")
            case "reset":
                return .reset
            case "audio_begin":
                return .audioBegin(
                    sampleRate: (dict["sampleRate"] as? NSNumber)?.doubleValue ?? 22_050,
                    channels: (dict["channels"] as? NSNumber)?.intValue ?? 1,
                    sentence: dict["text"] as? String ?? "",
                    isFiller: dict["filler"] as? Bool ?? false)
            case "audio_end":
                return .audioEnd
            case "tts_unavailable":
                return .ttsUnavailable
            case "done":
                let source = dict["source"] as? String
                return .done(text: dict["text"] as? String ?? "",
                             source: (source?.isEmpty ?? true) ? nil : source)
            case "error":
                throw VoiceStreamError.server(dict["message"] as? String ?? "unknown")
            default:
                // Unknown event types are skipped, not fatal: the server may
                // grow the protocol before every phone has updated.
                return nil
            }
        @unknown default:
            return nil
        }
    }
}
