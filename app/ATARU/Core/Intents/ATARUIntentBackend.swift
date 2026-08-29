import Foundation

/// The one network call an App Intent makes, and why it does not go through
/// `LiveATARUService`.
///
/// An intent invoked from the lock screen runs with `openAppWhenRun = false`,
/// which means there is no `AppState`, no `ATARUService` and quite possibly no
/// UI process at all - only the app's bundle, its Keychain and its
/// UserDefaults. So the address and the token are read from where they are
/// PERSISTED rather than from whatever object graph happens to be alive.
///
/// It asks `voice/answer` rather than `voice/speak` on purpose: Siri does its
/// own speaking, so pulling a WAV down and writing it into the download store
/// would be a megabyte and a file for audio nobody plays.
enum ATARUIntentBackend {

    /// Siri will not wait forever, and a spoken "your server didn't answer" is
    /// a better outcome than a request the user is left staring at. Shorter
    /// than the app's own 60s for that reason.
    static let timeout: TimeInterval = 25

    /// Asks the configured backend and returns the answer text.
    ///
    /// Throws `APIError`, whose messages are already written to be read by a
    /// person - which is exactly what a spoken failure needs.
    static func answer(to question: String) async throws -> String {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw APIError.malformedResponse("empty question") }

        let configuration = AppConfiguration.stored()
        guard let baseURL = configuration.baseURL else { throw APIError.notConfigured }
        let endpoints = EndpointBuilder(baseURL: baseURL,
                                        apiVersion: configuration.apiVersion)
        guard let url = endpoints.answer(trimmed) else { throw APIError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        // Same rule as `LiveATARUService.request(for:)`: the credential goes to
        // the configured backend and nowhere else. The URL was built from that
        // backend's own base, so the check is a belt on top of a brace - but it
        // is the check that would catch a base URL rewritten under us.
        if ATARUAuth.isTrusted(url, configuredHost: baseURL.host?.lowercased()),
           let token = KeychainStore().get(KeychainStore.bearerTokenAccount),
           !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let session = URLSession(configuration: Self.sessionConfiguration)
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw APIError.malformedResponse("not an HTTP response")
            }
            if let error = APIError.from(statusCode: http.statusCode) { throw error }
            let decoded = try decode(data)
            let text = decoded.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                throw APIError.malformedResponse("an answer with no text in it")
            }
            return text
        } catch let error as APIError {
            throw error
        } catch {
            throw APIError.from(error)
        }
    }

    private static var sessionConfiguration: URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        config.waitsForConnectivity = false
        // The answer is vault content. Nothing about it is worth caching on
        // disk for a question that was asked out loud once.
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return config
    }

    private static func decode(_ data: Data) throws -> DTO.VoiceAnswer {
        do {
            return try ATARUCoding.decoder.decode(DTO.VoiceAnswer.self, from: data)
        } catch {
            // The shape, never the payload - see `LiveATARUService.decode`.
            throw APIError.malformedResponse("DTO.VoiceAnswer")
        }
    }
}
