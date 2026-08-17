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

    func vocabulary() async throws -> [String] {
        guard let url = endpoints.vocabulary else { throw APIError.invalidURL }
        let (data, _) = try await perform(request(for: url))
        struct Roster: Decodable { let names: [String] }
        return try decode(Roster.self, from: data).names
    }

    func transcribe(samples: [Float]) async -> String? {
        await RemoteTranscriber.transcribe(samples: samples, endpoints: endpoints,
                                           token: tokenProvider())
    }

    func greeting() async throws -> SpokenAnswer {
        try await cannedLine(endpoints.greeting,
                             fallbackText: "ATARU here. What would you like to know?",
                             name: "greeting.wav")
    }

    func goodbye() async throws -> SpokenAnswer {
        try await cannedLine(endpoints.goodbye,
                             fallbackText: "Alright, talk later.",
                             name: "goodbye.wav")
    }

    private func cannedLine(_ url: URL?, fallbackText: String,
                            name: String) async throws -> SpokenAnswer {
        guard let url else { throw APIError.invalidURL }
        let (data, response) = try await perform(request(for: url))
        let audio = try await downloads.store(data, preferredName: name)
        return SpokenAnswer(
            text: response.value(forHTTPHeaderField: "X-Ataru-Text") ?? fallbackText,
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

    // MARK: - Plan

    func plan() async throws -> DailyPlan {
        guard let url = endpoints.url("api/plan") else { throw APIError.invalidURL }
        let (data, _) = try await perform(request(for: url))
        return try decode(DTO.Plan.self, from: data).domain
    }

    func planAdd(_ text: String, top3: Bool) async throws -> DailyPlan {
        try await planPost("api/plan/add", body: PlanAddBody(text: text, top3: top3))
    }

    func planSetDone(section: String, index: Int, done: Bool) async throws -> DailyPlan {
        try await planPost("api/plan/toggle",
                           body: PlanRowBody(section: section, index: index, done: done))
    }

    func planRemove(section: String, index: Int) async throws -> DailyPlan {
        try await planPost("api/plan/remove",
                           body: PlanRowBody(section: section, index: index, done: true))
    }

    private func planPost<Body: Encodable>(_ path: String, body: Body) async throws -> DailyPlan {
        guard let url = endpoints.url(path) else { throw APIError.invalidURL }
        var request = self.request(for: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, _) = try await perform(request)
        return try decode(DTO.Plan.self, from: data).domain
    }

    private struct PlanAddBody: Encodable {
        let text: String
        let top3: Bool
    }

    private struct PlanRowBody: Encodable {
        let section: String
        let index: Int
        let done: Bool
    }

    // MARK: - Morning call

    func morningSchedule() async throws -> MorningSchedule {
        guard let url = endpoints.url("api/morning/schedule") else {
            throw APIError.invalidURL
        }
        let (data, _) = try await perform(request(for: url))
        return try decode(DTO.MorningScheduleReply.self, from: data).domain
    }

    func setMorningSchedule(callTime: String, date: String?) async throws -> MorningSchedule {
        guard let url = endpoints.url("api/morning/schedule") else {
            throw APIError.invalidURL
        }
        var request = self.request(for: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // `date` is omitted rather than sent as null when it is nil: the
        // contract reads an absent key as "tomorrow", and an explicit null is
        // not the same claim.
        request.httpBody = try JSONEncoder().encode(
            MorningScheduleBody(call_time: callTime, date: date))
        let (data, _) = try await perform(request)
        return try decode(DTO.MorningScheduleReply.self, from: data).domain
    }

    /// "I'm up".
    ///
    /// `confirmed: false` is a legitimate answer, not a failure - the server
    /// bounds this to a call actually in flight and reports honestly when
    /// there was nothing to confirm. A missing route (an older backend) throws
    /// `notFound` from `perform`, and the caller treats that as "not recorded"
    /// for the same reason.
    ///
    /// A 2xx carrying something this cannot read is a THIRD thing and now says
    /// so. It used to fall through `try?` into `false`, which the button
    /// renders as "No call to confirm right now" - a specific claim about the
    /// server's state, made on the basis of not having understood the server
    /// at all. At seven in the morning that is the difference between "the
    /// calls will stop" and a redial ladder that is still running.
    @discardableResult
    func confirmMorningCall() async throws -> Bool {
        guard let url = endpoints.url("api/morning/confirm") else {
            throw APIError.invalidURL
        }
        var request = self.request(for: url)
        request.httpMethod = "POST"
        let (data, _) = try await perform(request)
        return try decode(DTO.MorningConfirmReply.self, from: data).confirmed ?? false
    }

    func morningCallState() async throws -> MorningCallState {
        guard let url = endpoints.url("api/morning/state") else {
            throw APIError.invalidURL
        }
        let (data, _) = try await perform(request(for: url))
        return try decode(DTO.MorningStateReply.self, from: data).domain
    }

    private struct MorningScheduleBody: Encodable {
        let call_time: String
        let date: String?
    }

    // MARK: - Notes

    func parseTasks(transcript: String) async throws -> [NoteTask] {
        guard let url = endpoints.url("api/parse-tasks") else { throw APIError.invalidURL }
        var request = self.request(for: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            ParseTasksDTO.Request(transcript: transcript))
        let (data, _) = try await perform(request)
        // Every row the model got wrong is dropped, not the whole reply: one
        // task returned without a title should not cost the user the other six.
        return try decode(ParseTasksDTO.Reply.self, from: data).tasks.compactMap(\.domain)
    }

    // MARK: - Cards

    func cardCatalog() async throws -> CardCatalog {
        guard let url = endpoints.url("api/cards/catalog") else { throw APIError.invalidURL }
        let (data, _) = try await perform(request(for: url))
        return try decode(CardCatalog.self, from: data)
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

    func registerPushToken(_ token: String, environment: String) async throws {
        guard let url = endpoints.url("api/push/register") else { throw APIError.invalidURL }
        var request = self.request(for: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            PushRegistration(token: token, platform: "ios", environment: environment)
        )
        let (data, _) = try await perform(request)
        // A 2xx that says `ok: false` is still a refusal, and without this the
        // app would report a token as registered that the server did not keep.
        // Lenient on shape: a body that will not decode, or one with no `ok`
        // at all, is taken at its HTTP word.
        if (try? decode(PushRegistrationReply.self, from: data))?.ok == false {
            throw APIError.malformedResponse("push/register returned ok: false")
        }
    }

    /// `platform` is what the contract asks for. `environment` is additive:
    /// the contract does not mention it, and a server ignoring unknown keys is
    /// unaffected - but without it a backend has to guess between the sandbox
    /// and production APNs hosts, and guessing wrong fails as BadDeviceToken
    /// with nothing to see. The VoIP registration already carries the same
    /// field for the same reason.
    private struct PushRegistration: Encodable {
        let token: String
        let platform: String
        let environment: String
    }

    private struct PushRegistrationReply: Decodable {
        let ok: Bool?
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
