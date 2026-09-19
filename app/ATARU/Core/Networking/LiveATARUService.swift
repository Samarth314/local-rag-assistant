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
        try await ask(question: question, stt: nil)
    }

    func ask(question: String, stt: STTConfidence?) async throws -> SpokenAnswer {
        guard let url = endpoints.speak(question) else { throw APIError.invalidURL }
        do {
            let (data, response) = try await perform(askRequest(for: url))
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
            return try await askForText(question, stt: stt)
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

    func bargeInTuning() async throws -> BargeInTuning {
        guard let url = endpoints.vocabulary else { throw APIError.invalidURL }
        let (data, _) = try await perform(request(for: url))
        // Every field optional, exactly like MorningStateReply: a server that
        // answers this path without the object, or with half of it, must leave
        // the app on its compiled constants rather than on a partial tuning.
        struct Reply: Decodable {
            struct Barge: Decodable {
                let level: Double?
                /// How far over the measured echo floor a level has to be.
                /// Optional like the rest, and a server that predates it
                /// leaves the app on its compiled 0.10 rather than on zero -
                /// zero would hand the whole decision back to `level`, which
                /// is the guess this knob exists to stop relying on.
                let margin: Double?
                let sustained_ms: Int?
                let cooldown_ms: Int?
            }
            let barge_in: Barge?
        }
        let barge = try decode(Reply.self, from: data).barge_in
        return BargeInTuning(level: barge?.level,
                             margin: barge?.margin,
                             sustainedMs: barge?.sustained_ms,
                             cooldownMs: barge?.cooldown_ms)
    }

    func transcribe(samples: [Float]) async -> Transcription? {
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

    private func askForText(_ question: String, stt: STTConfidence? = nil) async throws -> SpokenAnswer {
        guard let url = endpoints.answer(question) else { throw APIError.invalidURL }
        var request = self.askRequest(for: url)
        // A confidence object has to travel in a body, and a body means POST.
        // Only when there is something to send, though: with nothing measured
        // this stays the GET it has always been, so no existing call and no
        // older server changes behaviour over a field that is not there.
        if let stt, case let object = stt.jsonObject, !object.isEmpty,
           // The server's POST form reads `q` from the JSON body, not the
           // query string (appapi voice_answer_post), so the question rides
           // in the body too.
           let body = try? JSONSerialization.data(withJSONObject: ["q": question, "stt": object]) {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        let (data, _) = try await perform(request)
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

    // MARK: - Daily routine

    func routine() async throws -> DailyRoutine {
        guard let url = endpoints.url("api/health/routine") else {
            throw APIError.invalidURL
        }
        let (data, _) = try await perform(request(for: url))
        return try decode(DTO.Routine.self, from: data).domain
    }

    func routineSetDone(id: String, done: Bool) async throws -> DailyRoutine {
        guard let url = endpoints.url("api/health/routine/check") else {
            throw APIError.invalidURL
        }
        var request = self.request(for: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            RoutineCheckBody(id: id, done: done))
        let (data, _) = try await perform(request)
        return try decode(DTO.Routine.self, from: data).domain
    }

    private struct RoutineCheckBody: Encodable {
        let id: String
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

    // MARK: - Gym

    // openGym's state, reached through the bridge on the mini. See the vault's
    // records/work/opengym/APP-API.md, and `GymState` for why the document is
    // carried as JSON rather than as a struct.
    //
    // These four are the only methods in this file that look at a status code
    // themselves. They have to: a 409 is not a failure but an ANSWER that
    // carries the current document, and a 404 and a 503 are two different
    // claims about the server that must never both become "no workouts".

    func gymRevision() async throws -> Int {
        guard let url = endpoints.url("api/gym/rev") else { throw APIError.invalidURL }
        let (data, http) = try await gymPerform(request(for: url))
        try Self.refuseGym(status: http.statusCode, data: data)
        guard let rev = Self.gymReply(from: data)?.rev else {
            throw APIError.malformedResponse("gym/rev")
        }
        return rev
    }

    func gymState() async throws -> GymDocument {
        guard let url = endpoints.url("api/gym/state") else { throw APIError.invalidURL }
        let (data, http) = try await gymPerform(request(for: url))
        try Self.refuseGym(status: http.statusCode, data: data)
        guard let reply = Self.gymReply(from: data), let state = reply.state else {
            throw APIError.malformedResponse("gym/state")
        }
        return GymDocument(revision: reply.rev ?? state.revision, state: state)
    }

    func gymToday(date: String?) async throws -> GymToday {
        let query = date.map { [URLQueryItem(name: "date", value: $0)] } ?? []
        guard let url = endpoints.url("api/gym/today", query: query) else {
            throw APIError.invalidURL
        }
        let (data, http) = try await gymPerform(request(for: url))
        try Self.refuseGym(status: http.statusCode, data: data)
        guard let today = try? ATARUCoding.decoder.decode(GymToday.self, from: data) else {
            throw APIError.malformedResponse("gym/today")
        }
        return today
    }

    /// The catalogue. One call, 1324 rows, and the only gym route whose answer
    /// is the same for everybody - it is openGym's dataset, not Arya's
    /// document, which is why the store may hold it for a day.
    func gymLibrary() async throws -> GymLibrary {
        guard let url = endpoints.url("api/gym/library") else { throw APIError.invalidURL }
        let (data, http) = try await gymPerform(request(for: url))
        try Self.refuseGym(status: http.statusCode, data: data)
        guard let library = try? ATARUCoding.decoder.decode(GymLibrary.self, from: data)
        else {
            throw APIError.malformedResponse("gym/library")
        }
        return library
    }

    func gymWrite(state: GymState, baseRev: Int) async throws -> GymWriteResult {
        guard let url = endpoints.url("api/gym/state") else { throw APIError.invalidURL }
        var request = self.request(for: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // The whole document, minus the three fields the server owns. See
        // `GymState.bodyForWrite`.
        let body: [String: JSONValue] = ["state": .object(state.bodyForWrite),
                                         "baseRev": .int(baseRev)]
        request.httpBody = try body.jsonData()

        let (data, http) = try await gymPerform(request)
        // 409 is the revision check doing its job, not an error: the answer
        // carries the document that IS current, and the caller merges against
        // it. Re-sending our own copy with the new number is what this exists
        // to prevent.
        if http.statusCode == 409 {
            guard let reply = Self.gymReply(from: data), let current = reply.state else {
                throw APIError.malformedResponse("gym/state conflict")
            }
            return .conflict(GymDocument(revision: reply.rev ?? current.revision,
                                         state: current))
        }
        try Self.refuseGym(status: http.statusCode, data: data)
        guard let reply = Self.gymReply(from: data), let stored = reply.state else {
            throw APIError.malformedResponse("gym/state write")
        }
        return .stored(GymDocument(revision: reply.rev ?? stored.revision, state: stored))
    }

    /// Like `perform`, but hands back non-2xx answers instead of throwing -
    /// three of the gym's status codes carry a body worth reading.
    private func gymPerform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw APIError.malformedResponse("not an HTTP response")
            }
            return (data, http)
        } catch let error as APIError {
            throw error
        } catch {
            throw APIError.from(error)
        }
    }

    private struct GymReply: Decodable {
        let ok: Bool?
        let rev: Int?
        let state: GymState?
        let error: String?
        let conflict: Bool?
    }

    private static func gymReply(from data: Data) -> GymReply? {
        try? ATARUCoding.decoder.decode(GymReply.self, from: data)
    }

    /// Turns the gym's own failure codes into the two claims the screen is
    /// allowed to make. Neither may ever be drawn as an empty week.
    private static func refuseGym(status: Int, data: Data) throws {
        switch status {
        case 200...299:
            return
        case 404:
            // Either `ATARU_GYM=1` is unset (the documented body) or the route
            // is not on this server at all. Both mean the same thing to the
            // phone: the feature is not there.
            throw GymError.disabled
        case 503:
            let detail = gymReply(from: data)?.error ?? ""
            throw GymError.unavailable(
                detail.replacingOccurrences(of: "gym unavailable: ", with: ""))
        default:
            throw APIError.from(statusCode: status) ?? APIError.server(status: status)
        }
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

    /// `POST /voip/hangup`, with the same bearer every other route carries.
    ///
    /// The body is built by `CallHangup` rather than here, because the shape
    /// is the contract and the contract is what the tests pin down.
    func reportCallHangup(reason: CallHangupReason, at moment: Date) async throws {
        guard let url = endpoints.url("voip/hangup") else { throw APIError.invalidURL }
        var request = self.request(for: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try CallHangup.encode(reason: reason, at: moment)
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
    ///
    /// THE ALERT TOKEN GOES HERE AND ONLY HERE. It is not also posted to
    /// `/voip/register`, which is the morning ring's registry: the two are
    /// different tokens for different APNs topics, and a PushKit token in the
    /// alert registry (or the reverse) fails as BadDeviceToken with nothing
    /// anywhere saying why. The paired morning alert is sent from THIS
    /// registry - see the server's `push.ring_alert` - so nothing about the
    /// two-push morning needs a second registration.
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

    /// A request that is part of the conversation, rather than a lookup.
    ///
    /// Only asks carry the session header. Document reads, the vocabulary
    /// roster and the health poll are not turns, and stamping the conversation
    /// on those would keep it alive purely because the app was open - which is
    /// the opposite of the idle window's point (see ConversationID).
    ///
    /// A header rather than a query item: it is not part of the resource being
    /// addressed, and it stays out of the URL column of every access log.
    private func askRequest(for url: URL) -> URLRequest {
        var request = self.request(for: url)
        request.setValue(ConversationID.shared.current(),
                         forHTTPHeaderField: "X-Ataru-Session")
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
