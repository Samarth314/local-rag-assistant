import Foundation

/// Talks to a real ATARU backend over the user's Tailnet or LAN.
///
/// Every request goes to the configured base URL and nowhere else. There is no
/// analytics endpoint, no crash reporter and no third-party host anywhere in
/// this file — that is a product property of ATARU, not an oversight. See
/// PRIVACY.md.
final class LiveATARUService: ATARUService, @unchecked Sendable {

    private let baseURL: URL
    private let endpoints: EndpointBuilder
    private let session: URLSession
    private let tokenProvider: @Sendable () -> String?
    private let downloads: DocumentDownloadStore

    init(configuration: AppConfiguration,
         tokenProvider: @escaping @Sendable () -> String?,
         downloads: DocumentDownloadStore = .shared,
         session: URLSession? = nil) throws {
        guard let baseURL = configuration.baseURL else { throw APIError.notConfigured }
        self.baseURL = baseURL
        self.endpoints = EndpointBuilder(baseURL: baseURL, apiVersion: configuration.apiVersion)
        self.tokenProvider = tokenProvider
        self.downloads = downloads

        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = configuration.requestTimeout
            config.timeoutIntervalForResource = configuration.requestTimeout * 2
            config.waitsForConnectivity = false
            // Responses are vault content. Keeping them out of the URL cache
            // means they live only as long as the objects holding them.
            config.urlCache = nil
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: config)
        }
    }

    // MARK: - Status

    func checkStatus() async throws -> String? {
        guard let url = endpoints.health else { throw APIError.invalidURL }
        let (data, _) = try await perform(request(for: url))
        return try decode(DTO.Health.self, from: data).status
    }

    // MARK: - Documents

    func documents(query: String?, category: DocumentCategory) async throws -> DocumentLibraryPage {
        guard let url = endpoints.documents(query: query, category: category) else {
            throw APIError.invalidURL
        }
        let (data, _) = try await perform(request(for: url))
        return try decode(DTO.DocumentList.self, from: data).domain
    }

    func document(id: String) async throws -> IndexedDocument {
        guard let url = endpoints.document(id) else { throw APIError.invalidURL }
        let (data, _) = try await perform(request(for: url))
        return try decode(DTO.DocumentSummary.self, from: data).domain
    }

    func documentContent(id: String) async throws -> DocumentPayload {
        guard let url = endpoints.documentContent(id) else { throw APIError.invalidURL }
        let (data, response) = try await perform(request(for: url))

        // Set by the server when it could not read the original file and
        // returned text rebuilt from the index instead. The UI says so before
        // the user sends it on — "the PDF" and "our extract of the PDF" are
        // not the same artefact to hand someone.
        let reconstructed = response.value(forHTTPHeaderField: "X-Ataru-Reconstructed") == "1"
        let name = Self.filename(from: response) ?? "document"
        let fileURL = try await downloads.store(data, preferredName: name)
        return DocumentPayload(url: fileURL, isReconstructed: reconstructed)
    }

    // MARK: - Voice

    func ask(question: String) async throws -> SpokenAnswer {
        guard let url = endpoints.speak(question) else { throw APIError.invalidURL }
        do {
            let (data, response) = try await perform(request(for: url))
            let audio = try await downloads.store(data, preferredName: "answer.wav")
            return SpokenAnswer(
                text: response.value(forHTTPHeaderField: "X-Ataru-Text") ?? "",
                source: response.value(forHTTPHeaderField: "X-Ataru-Source")
                    .flatMap { $0.isEmpty ? nil : $0 },
                audioURL: audio
            )
        } catch APIError.server(status: 503) {
            // 503 from /voice/speak means the answer is fine but the server
            // has no TTS engine. Falling back to the text route lets the phone
            // speak it locally rather than failing the whole question.
            return try await askForText(question)
        }
    }

    func voiceStream() -> VoiceStreamSession? {
        VoiceStreamSession(baseURL: baseURL, token: tokenProvider())
    }

    func greeting() async throws -> SpokenAnswer {
        guard let url = endpoints.greeting else { throw APIError.invalidURL }
        let (data, response) = try await perform(request(for: url))
        let audio = try await downloads.store(data, preferredName: "greeting.wav")
        return SpokenAnswer(
            text: response.value(forHTTPHeaderField: "X-Ataru-Text")
                ?? "ATARU here. What would you like to know?",
            source: nil,
            audioURL: audio
        )
    }

    private func askForText(_ question: String) async throws -> SpokenAnswer {
        guard let url = endpoints.answer(question) else { throw APIError.invalidURL }
        let (data, _) = try await perform(request(for: url))
        let answer = try decode(DTO.VoiceAnswer.self, from: data)
        return SpokenAnswer(text: answer.text, source: answer.source, audioURL: nil)
    }

    // MARK: - Calls

    func registerVoIPToken(_ token: String, environment: String) async throws {
        guard let url = endpoints.url("voip/register") else { throw APIError.invalidURL }
        var request = self.request(for: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            VoIPRegistration(token: token, environment: environment, name: Self.deviceName)
        )
        _ = try await perform(request)
    }

    private struct VoIPRegistration: Encodable {
        let token: String
        let environment: String
        let name: String
    }

    /// A fixed label, so the server's device list is readable.
    ///
    /// Deliberately not `UIDevice.current.name`: people routinely set that to
    /// their own name ("Samarth's iPhone"), and a device registration has no
    /// business carrying a person's name off the phone.
    private static let deviceName = "iPhone"

    // MARK: - Plumbing

    private func request(for url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        if let token = tokenProvider(), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw APIError.malformedResponse("not an HTTP response")
            }
            if let error = APIError.from(statusCode: http.statusCode) { throw error }
            return (data, http)
        } catch let error as APIError {
            throw error
        } catch {
            throw APIError.from(error)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try ATARUCoding.decoder.decode(type, from: data)
        } catch {
            // Carries the expected shape, never the payload: the payload is
            // vault content and error strings end up in logs.
            throw APIError.malformedResponse(String(describing: type))
        }
    }

    /// Pulls a filename out of `Content-Disposition`, so a shared file arrives
    /// with its real name rather than an opaque id.
    static func filename(from response: HTTPURLResponse) -> String? {
        guard let disposition = response.value(forHTTPHeaderField: "Content-Disposition") else {
            return response.suggestedFilename
        }
        for part in disposition.split(separator: ";") {
            let piece = part.trimmingCharacters(in: .whitespaces)
            guard piece.lowercased().hasPrefix("filename=") else { continue }
            let value = piece.dropFirst("filename=".count)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if !value.isEmpty { return value }
        }
        return response.suggestedFilename
    }
}
