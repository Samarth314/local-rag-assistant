import XCTest
@testable import ATARU

/// A files backend that answers instantly and records what it was asked.
///
/// Records the REQUESTS, not just the answers: half of what the browser has to
/// get right is what it sends - the page it asks for, the filters it carries,
/// and the history it attaches to a narrowing.
private final class FilesStubService: ATARUService, @unchecked Sendable {
    var result = FileSearchResult.empty
    var narrowing: FilesNarrowing?
    var searchError: Error?
    private(set) var requests: [FileSearchRequest] = []
    private(set) var narrowCalls: [(q: String, filters: FileFilters,
                                    history: [FileNarrowStep])] = []

    func checkStatus() async throws -> String? { "ok" }

    func documents(query: String?, category: DocumentCategory) async throws -> DocumentLibraryPage {
        .empty
    }
    func document(id: String) async throws -> IndexedDocument { throw APIError.notFound }
    func documentContent(id: String) async throws -> DocumentPayload { throw APIError.notFound }
    func ask(question: String) async throws -> SpokenAnswer {
        SpokenAnswer(text: "", source: nil, audioURL: nil)
    }
    func vocabulary() async throws -> [String] { [] }
    func transcribe(samples: [Float]) async -> Transcription? { nil }
    func registerVoIPToken(_ token: String, environment: String) async throws {}

    func filesSearch(_ request: FileSearchRequest) async throws -> FileSearchResult {
        requests.append(request)
        if let searchError { throw searchError }
        return result
    }

    func filesNarrow(q: String, filters: FileFilters,
                     history: [FileNarrowStep]) async throws -> FilesNarrowing {
        narrowCalls.append((q, filters, history))
        guard let narrowing else { throw APIError.notFound }
        return narrowing
    }
}

private func hit(_ id: String, name: String = "a.pdf",
                 kind: FileKind = .pdf) -> FileHit {
    FileHit(id: id, path: "Projects/X/\(name)", name: name, kind: kind)
}

private func page(_ hits: [FileHit], total: Int? = nil,
                  facets: FileFacets = .empty) -> FileSearchResult {
    FileSearchResult(total: total ?? hits.count, page: 1, pageSize: 30,
                     hits: hits, facets: facets)
}

// MARK: - Decoding

/// The wire shapes in the contract, byte for byte. These are what the server
/// promised; anything the app cannot read here it cannot read in production.
final class FilesDecodingTests: XCTestCase {

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    func testSearchResultDecodesTheContractShape() throws {
        let json = """
        {"ok": true, "total": 132, "page": 2, "page_size": 30,
         "hits": [
           {"id": "abc123", "path": "Projects/Robolabs/Tournaments/run.xlsx",
            "name": "run.xlsx", "title": "run", "ext": "xlsx", "kind": "sheet",
            "pod": "work", "umbrella": "Robolabs", "project": "Tournaments",
            "mtime": "2026-08-14T09:12:00Z", "size": 98304,
            "location": "local", "snippet": "match schedule",
            "score": 0.82, "has_text": true}
         ],
         "facets": {"pod": {"work": 4}, "umbrella": {"Robolabs": 11},
                    "kind": {"sheet": 3, "pdf": 8}, "year": {"2026": 9}}}
        """
        let result = try decode(FileSearchResult.self, json)
        XCTAssertEqual(result.total, 132)
        XCTAssertEqual(result.page, 2)
        XCTAssertEqual(result.pageSize, 30)
        XCTAssertEqual(result.hits.count, 1)
        let file = try XCTUnwrap(result.hits.first)
        XCTAssertEqual(file.id, "abc123")
        XCTAssertEqual(file.kind, .sheet)
        XCTAssertEqual(file.umbrella, "Robolabs")
        XCTAssertEqual(file.project, "Tournaments")
        XCTAssertEqual(file.size, 98_304)
        XCTAssertEqual(file.location, .local)
        XCTAssertEqual(file.snippet, "match schedule")
        XCTAssertEqual(file.score ?? 0, 0.82, accuracy: 0.0001)
        XCTAssertTrue(file.hasText)
        XCTAssertNotNil(file.mtime)
        XCTAssertEqual(result.facets.umbrella["Robolabs"], 11)
        XCTAssertEqual(result.facets.year["2026"], 9)
    }

    /// A BROWSE carries no snippet and no score, because neither exists
    /// without a query. Both have to be absent-able, not zero-able.
    func testHitDecodesWithoutSnippetOrScore() throws {
        let json = """
        {"id": "x", "path": "Projects/Book/Seer/ch4.md", "name": "ch4.md",
         "title": "ch4", "ext": "md", "kind": "text", "umbrella": "Book",
         "project": "Seer", "mtime": "2026-09-01T00:00:00Z", "size": 1200,
         "location": "local", "has_text": true}
        """
        let file = try decode(FileHit.self, json)
        XCTAssertNil(file.snippet)
        XCTAssertNil(file.score)
        XCTAssertEqual(file.kind, .text)
    }

    /// A row missing everything optional still has to render rather than
    /// failing the page it is on.
    func testHitSurvivesAMinimalRow() throws {
        let file = try decode(FileHit.self, #"{"id": "y", "path": "a/b/Report.PDF"}"#)
        XCTAssertEqual(file.name, "Report.PDF")
        XCTAssertEqual(file.title, "Report.PDF")
        XCTAssertEqual(file.ext, "pdf")
        XCTAssertEqual(file.kind, .other)
        XCTAssertEqual(file.location, .local)
        XCTAssertFalse(file.hasText)
        XCTAssertNil(file.mtime)
    }

    /// `nas-away` is the whole reason the badge exists, so the exact hyphen
    /// spelling is pinned.
    func testAwayLocationDecodes() throws {
        let file = try decode(FileHit.self,
                              #"{"id": "z", "path": "a/b.mp4", "location": "nas-away"}"#)
        XCTAssertEqual(file.location, .nasAway)
        XCTAssertTrue(file.location.isAway)
    }

    /// An unknown kind must not fail the page, and an unknown location must
    /// not silently claim a file is away.
    func testUnknownEnumValuesDegradeRatherThanThrow() throws {
        let file = try decode(FileHit.self, """
        {"id": "z", "path": "a/b.dwg", "kind": "cad", "location": "somewhere"}
        """)
        XCTAssertEqual(file.kind, .other)
        XCTAssertEqual(file.location, .local)
    }

    func testDetailDecodesTextCharsAndExtractedAtFromInsideFile() throws {
        let json = """
        {"ok": true,
         "file": {"id": "abc", "path": "Projects/Career/Resumes/cv.pdf",
                  "name": "cv.pdf", "kind": "pdf", "location": "local",
                  "has_text": true, "text_chars": 8421,
                  "extracted_at": "2026-09-10T11:02:44.318000Z"},
         "previewable": true, "viewer": "pdf"}
        """
        let detail = try decode(FileDetail.self, json)
        XCTAssertEqual(detail.file.id, "abc")
        XCTAssertEqual(detail.textChars, 8_421)
        XCTAssertNotNil(detail.extractedAt)
        XCTAssertTrue(detail.previewable)
        XCTAssertEqual(detail.viewer, .pdf)
    }

    func testUnknownViewerBecomesNone() throws {
        let detail = try decode(FileDetail.self, """
        {"file": {"id": "a", "path": "a/b.zip"}, "previewable": true, "viewer": "holodeck"}
        """)
        XCTAssertEqual(detail.viewer, FileViewerKind.none)
    }

    func testNarrowResponseDecodes() throws {
        let json = """
        {"ok": true, "query": "tournament",
         "filters": {"umbrella": ["Robolabs"], "kind": ["sheet"],
                     "since": "2025-01-01", "until": "2025-12-31"},
         "explanation": "Narrowed to spreadsheets in Robolabs from 2025.",
         "result": {"ok": true, "total": 2, "page": 1, "page_size": 30,
                    "hits": [], "facets": {}}}
        """
        let narrowing = try decode(FilesNarrowing.self, json)
        XCTAssertEqual(narrowing.query, "tournament")
        XCTAssertEqual(narrowing.filters.umbrellas, ["Robolabs"])
        XCTAssertEqual(narrowing.filters.kinds, [.sheet])
        XCTAssertEqual(narrowing.filters.year, 2025)
        XCTAssertEqual(narrowing.explanation,
                       "Narrowed to spreadsheets in Robolabs from 2025.")
        XCTAssertEqual(narrowing.result.total, 2)
    }

    /// The query string takes repeated params, so an echoed filter set may
    /// reasonably render a single value as a bare string. Dropping those would
    /// silently ignore the narrowing the user just asked for.
    func testFiltersAcceptAScalarWhereAListBelongs() throws {
        let filters = try decode(FileFilters.self,
                                 #"{"kind": "pdf", "umbrella": "Career"}"#)
        XCTAssertEqual(filters.kinds, [.pdf])
        XCTAssertEqual(filters.umbrellas, ["Career"])
    }

    func testFiltersRoundTripThroughJSON() throws {
        var filters = FileFilters(umbrellas: ["Research"], kinds: [.sheet, .pdf],
                                  exts: ["xlsx"], location: .nasAway)
        filters.setYear(2025)
        let data = try JSONEncoder().encode(filters)
        XCTAssertEqual(try JSONDecoder().decode(FileFilters.self, from: data), filters)
    }

    /// The listing is round-tripped through `TileCache` on every open, so a
    /// hit that encodes to something its own decoder cannot read would lose
    /// the cache silently.
    func testHitRoundTripsThroughTheCacheEncoder() throws {
        let original = FileHit(id: "a", path: "p/b.pdf", name: "b.pdf",
                               kind: .pdf, umbrella: "Book",
                               mtime: Date(timeIntervalSince1970: 1_780_000_000),
                               size: 12, location: .nasAway, hasText: true)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(FileHit.self, from: data)
        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.location, .nasAway)
        XCTAssertEqual(decoded.kind, .pdf)
        XCTAssertEqual(decoded.mtime?.timeIntervalSince1970 ?? 0,
                       original.mtime?.timeIntervalSince1970 ?? -1, accuracy: 1)
    }

    func testISO8601AcceptsTheThreeShapesAndRefusesNonsense() {
        XCTAssertNotNil(ISO8601Time.parse("2026-09-19T08:14:02Z"))
        XCTAssertNotNil(ISO8601Time.parse("2026-09-19T08:14:02.512000Z"))
        XCTAssertNotNil(ISO8601Time.parse("2026-09-19T08:14:02"))
        XCTAssertNotNil(ISO8601Time.parse("2026-09-19"))
        XCTAssertNil(ISO8601Time.parse(nil))
        XCTAssertNil(ISO8601Time.parse(""))
        XCTAssertNil(ISO8601Time.parse("yesterday"))
    }
}

// MARK: - Query encoding

final class FilesQueryTests: XCTestCase {

    private func string(_ items: [URLQueryItem]) -> String {
        var components = URLComponents()
        components.queryItems = items
        return components.percentEncodedQuery ?? ""
    }

    /// LIST PARAMS REPEAT. A comma-joined `kind=pdf,slides` reads to the
    /// server as one extension nobody has, and it would work in every hand
    /// test because the browse case never sets two.
    func testListParametersAreRepeatedNotJoined() {
        let filters = FileFilters(umbrellas: ["Robolabs", "Career"],
                                  kinds: [.pdf, .slides])
        let items = FilesQuery.items(q: nil, filters: filters, sort: .name,
                                     page: 1, pageSize: 30)
        XCTAssertEqual(items.filter { $0.name == "umbrella" }.map(\.value),
                       ["Robolabs", "Career"])
        XCTAssertEqual(items.filter { $0.name == "kind" }.map(\.value),
                       ["pdf", "slides"])
        XCTAssertFalse(string(items).contains(","))
    }

    func testFullQueryStringOrderIsStable() {
        var filters = FileFilters(pods: ["work"], umbrellas: ["Research"],
                                  projects: ["Wind turbine paper"],
                                  kinds: [.sheet], exts: ["xlsx"],
                                  location: .nasAway)
        filters.setYear(2025)
        let items = FilesQuery.items(q: "outage", filters: filters,
                                     sort: .relevance, page: 3, pageSize: 25)
        XCTAssertEqual(items.map(\.name),
                       ["q", "pod", "umbrella", "project", "kind", "ext",
                        "since", "until", "location", "sort", "page", "page_size"])
        XCTAssertEqual(items.last?.value, "25")
        XCTAssertEqual(string(items).contains("location=nas-away"), true)
    }

    /// A whitespace-only query is not a search, and sending it would turn a
    /// browse into a search that matches nothing.
    func testBlankQueryIsOmitted() {
        let items = FilesQuery.items(q: "   ", filters: .none, sort: .mtimeDesc,
                                     page: 1, pageSize: 30)
        XCTAssertFalse(items.contains { $0.name == "q" })
    }

    func testRelevanceIsOfferedOnlyWhileSearching() {
        XCTAssertTrue(FileSort.options(searching: true).contains(.relevance))
        XCTAssertFalse(FileSort.options(searching: false).contains(.relevance))
    }
}

// MARK: - Chips

final class FileFilterChipTests: XCTestCase {

    func testEveryAppliedFilterProducesOneChip() {
        var filters = FileFilters(pods: ["health"], umbrellas: ["ATARU"],
                                  kinds: [.pdf], exts: ["md"], location: .local)
        filters.setYear(2024)
        XCTAssertEqual(filters.chips.count, 6)
    }

    func testChipsAddAndRemoveRoundTrip() {
        let start = FileFilters(umbrellas: ["Career"])
        var filters = start
        filters.toggle(kind: .slides)
        filters.toggle(pod: "work")
        XCTAssertEqual(filters.chips.count, 3)

        for chip in filters.chips where chip.kind != .umbrella("Career") {
            filters = filters.removing(chip)
        }
        XCTAssertEqual(filters, start)
    }

    /// The year chip is DERIVED from `since`/`until` so the filter set stays
    /// exactly the server's parameter list. Removing it has to clear both.
    func testYearChipIsOneChipOverTwoFields() {
        var filters = FileFilters()
        filters.setYear(2025)
        XCTAssertEqual(filters.since, "2025-01-01")
        XCTAssertEqual(filters.until, "2025-12-31")
        let chips = filters.chips
        XCTAssertEqual(chips.count, 1)
        XCTAssertEqual(chips.first?.label, "2025")

        let cleared = filters.removing(chips[0])
        XCTAssertNil(cleared.since)
        XCTAssertNil(cleared.until)
        XCTAssertTrue(cleared.isEmpty)
    }

    /// A half-open range is two chips, not a mislabelled year.
    func testPartialDateBoundsAreSeparateChips() {
        let filters = FileFilters(since: "2025-03-01", until: "2025-12-31")
        XCTAssertNil(filters.year)
        XCTAssertEqual(filters.chips.count, 2)
    }

    func testTogglingTwiceIsANoOp() {
        var filters = FileFilters()
        filters.toggle(umbrella: "Book")
        filters.toggle(umbrella: "Book")
        XCTAssertTrue(filters.isEmpty)
    }

    /// The rail order is Arya's own reach order, and a name this build has
    /// never heard of is appended rather than dropped.
    func testUmbrellaRailKeepsReachOrderAndKeepsStrangers() {
        let facets = FileFacets(umbrella: ["Career": 3, "Robolabs": 9,
                                           "Zephyr": 1, "Book": 2])
        XCTAssertEqual(facets.orderedUmbrellas.map(\.name),
                       ["Robolabs", "Career", "Book", "Zephyr"])
    }

    func testZeroCountFacetsAreHidden() {
        let facets = FileFacets(umbrella: ["Career": 0], kind: ["pdf": 0, "text": 2])
        XCTAssertTrue(facets.orderedUmbrellas.isEmpty)
        XCTAssertEqual(facets.orderedKinds.map(\.kind), [.text])
    }
}

// MARK: - Payload routing

final class AnswerPayloadRoutingTests: XCTestCase {

    func testDocumentOpensTheViewer() {
        let ref = DocumentRef(id: "a", title: "T", fileType: "pdf",
                              previewable: true, source: .files)
        XCTAssertEqual(AnswerPayloadRouter.route(document: ref, files: nil),
                       .openViewer(ref))
    }

    func testListingOpensTheBrowser() {
        let payload = FilesPayload(query: "tournament",
                                   filters: FileFilters(umbrellas: ["Robolabs"]),
                                   total: 4)
        XCTAssertEqual(AnswerPayloadRouter.route(document: nil, files: payload),
                       .openFiles(payload))
    }

    /// Both can arrive together, and only one of them can be opened. The
    /// specific artefact wins: he asked for a file and got one.
    func testDocumentWinsOverListing() {
        let ref = DocumentRef(id: "a", title: "T", fileType: "pdf", previewable: true)
        let payload = FilesPayload(query: "", filters: .none, total: 9)
        XCTAssertEqual(AnswerPayloadRouter.route(document: ref, files: payload),
                       .openViewer(ref))
    }

    func testNeitherRoutesNowhere() {
        XCTAssertEqual(AnswerPayloadRouter.route(document: nil, files: nil), .none)
    }

    /// A ref with no `source` is a vault record, because that is the index
    /// that existed before this one.
    func testDocumentSourceDefaultsToTheVault() {
        XCTAssertEqual(DocumentSource(serverValue: nil), .vault)
        XCTAssertEqual(DocumentSource(serverValue: ""), .vault)
        XCTAssertEqual(DocumentSource(serverValue: "files"), .files)
        XCTAssertEqual(DocumentSource(serverValue: "FILES"), .files)
        XCTAssertEqual(DocumentSource(serverValue: "somewhere-new"), .vault)
    }

    func testFilesPayloadBuildsFromTheWebSocketDictionary() throws {
        let payload = try XCTUnwrap(FilesPayload(json: [
            "query": "run sheet",
            "filters": ["umbrella": ["Robolabs"], "kind": ["sheet"]],
            "total": 3
        ]))
        XCTAssertEqual(payload.query, "run sheet")
        XCTAssertEqual(payload.filters.umbrellas, ["Robolabs"])
        XCTAssertEqual(payload.filters.kinds, [.sheet])
        XCTAssertEqual(payload.total, 3)
    }

    func testAnswerDocumentDTOCarriesSourceAndURL() throws {
        let json = """
        {"text": "Opening it.", "source": null, "model": "ataru",
         "document": {"id": "f1", "title": "LAMC transcript",
                      "file_type": "pdf", "previewable": true,
                      "source": "files", "url": "/api/files/f1/content"}}
        """
        let answer = try JSONDecoder().decode(DTO.VoiceAnswer.self, from: Data(json.utf8))
        let ref = try XCTUnwrap(answer.document?.domain)
        XCTAssertEqual(ref.source, .files)
        XCTAssertEqual(ref.url, "/api/files/f1/content")
        XCTAssertNil(answer.files)
    }
}

// MARK: - Demo narrowing

final class DemoFilesNarrowTests: XCTestCase {

    func testFixtureCoversEveryUmbrellaAndEnoughRows() {
        XCTAssertEqual(DemoFilesIndex.hits.count, 60)
        let umbrellas = Set(DemoFilesIndex.hits.compactMap(\.umbrella))
        XCTAssertEqual(umbrellas, Set(FileFacets.umbrellaOrder))
        XCTAssertTrue(DemoFilesIndex.hits.contains { $0.location.isAway })
    }

    func testKindWordsBecomeAKindFilter() {
        let narrowing = DemoFilesIndex.narrow(q: "just the spreadsheets",
                                              filters: .none, history: [])
        XCTAssertEqual(narrowing.filters.kinds, [.sheet])
        XCTAssertTrue(narrowing.query.isEmpty)
        XCTAssertTrue(narrowing.result.hits.allSatisfy { $0.kind == .sheet })
    }

    func testYearBecomesADateRange() {
        let narrowing = DemoFilesIndex.narrow(q: "2025 only", filters: .none, history: [])
        XCTAssertEqual(narrowing.filters.year, 2025)
    }

    /// Two-word umbrellas are matched against the whole sentence, because
    /// neither "graduate" nor "school" is an umbrella on its own - and neither
    /// word may survive into the query afterwards.
    func testMultiWordUmbrellaIsMatchedAndConsumed() {
        let narrowing = DemoFilesIndex.narrow(q: "show me graduate school pdfs",
                                              filters: .none, history: [])
        XCTAssertEqual(narrowing.filters.umbrellas, ["Graduate School"])
        XCTAssertEqual(narrowing.filters.kinds, [.pdf])
        XCTAssertTrue(narrowing.query.isEmpty)
        XCTAssertTrue(narrowing.result.total > 0)
    }

    func testWhateverIsLeftBecomesTheQuery() {
        let narrowing = DemoFilesIndex.narrow(q: "find the tournament pdfs",
                                              filters: .none, history: [])
        XCTAssertEqual(narrowing.query, "tournament")
        XCTAssertEqual(narrowing.filters.kinds, [.pdf])
    }

    /// A rung that names only filters keeps the standing query, which is read
    /// back off the history - the request carries only the new utterance.
    func testAFilterOnlyRungKeepsTheStandingQuery() {
        let history = [FileNarrowStep(q: "tournament", filters: .none)]
        let narrowing = DemoFilesIndex.narrow(q: "just the spreadsheets",
                                              filters: FileFilters(), history: history)
        XCTAssertEqual(narrowing.query, "tournament")
        XCTAssertEqual(narrowing.filters.kinds, [.sheet])
    }

    func testNarrowingAccumulatesOntoFiltersAlreadyApplied() {
        let first = DemoFilesIndex.narrow(q: "robolabs", filters: .none, history: [])
        XCTAssertEqual(first.filters.umbrellas, ["Robolabs"])
        let second = DemoFilesIndex.narrow(q: "spreadsheets only",
                                           filters: first.filters,
                                           history: [FileNarrowStep(q: "robolabs",
                                                                    filters: .none)])
        XCTAssertEqual(second.filters.umbrellas, ["Robolabs"])
        XCTAssertEqual(second.filters.kinds, [.sheet])
    }

    /// Nothing recognised narrows nothing, and the explanation says so rather
    /// than claiming a filter that was never applied.
    func testAnUnrecognisableRungSaysSo() {
        let narrowing = DemoFilesIndex.narrow(q: "the of and", filters: .none, history: [])
        XCTAssertTrue(narrowing.filters.isEmpty)
        XCTAssertTrue(narrowing.explanation.contains("unchanged"))
    }

    func testNasWordSelectsAwayFiles() {
        let narrowing = DemoFilesIndex.narrow(q: "what's on the nas", filters: .none,
                                              history: [])
        XCTAssertEqual(narrowing.filters.location, .nasAway)
        XCTAssertTrue(narrowing.result.hits.allSatisfy { $0.location.isAway })
        XCTAssertTrue(narrowing.result.total > 0)
    }

    func testPagingWalksTheWholeIndexWithoutRepeating() {
        var seen: [String] = []
        for page in 1...6 {
            let result = DemoFilesIndex.search(
                FileSearchRequest(q: nil, filters: .none, sort: .name,
                                  page: page, pageSize: 10))
            seen += result.hits.map(\.id)
        }
        XCTAssertEqual(seen.count, 60)
        XCTAssertEqual(Set(seen).count, 60)
    }

    func testSearchScoresAndSnippetsOnlyExistWithAQuery() {
        let browse = DemoFilesIndex.search(FileSearchRequest())
        XCTAssertTrue(browse.hits.allSatisfy { $0.score == nil && $0.snippet == nil })
        let searched = DemoFilesIndex.search(FileSearchRequest(q: "resume"))
        XCTAssertTrue(searched.total > 0)
        XCTAssertTrue(searched.hits.allSatisfy { $0.score != nil && $0.snippet != nil })
    }

    func testAFileQuestionAnswersWithAListingPayload() throws {
        let answer = try XCTUnwrap(
            DemoFilesIndex.fileIntent(for: "show me the robolabs spreadsheets"))
        let payload = try XCTUnwrap(answer.files)
        XCTAssertEqual(payload.filters.umbrellas, ["Robolabs"])
        XCTAssertEqual(payload.filters.kinds, [.sheet])
        XCTAssertNil(answer.document)
    }

    func testANonFileQuestionIsNotIntercepted() {
        XCTAssertNil(DemoFilesIndex.fileIntent(for: "what is the weather"))
    }
}

// MARK: - The browser

@MainActor
final class FilesViewModelTests: XCTestCase {

    private func model(_ service: FilesStubService) -> FilesViewModel {
        let model = FilesViewModel()
        model.configure(service: service, cacheRoot: nil)
        return model
    }

    func testReloadAsksForTheFirstPageWithTheAppliedFilters() async {
        let service = FilesStubService()
        service.result = page([hit("1")], total: 1)
        let model = self.model(service)
        model.toggle(umbrella: "Career")
        await settle()
        let request = try? XCTUnwrap(service.requests.last)
        XCTAssertEqual(request?.page, 1)
        XCTAssertEqual(request?.filters.umbrellas, ["Career"])
    }

    func testLoadMoreAppendsAndDeduplicates() async {
        let service = FilesStubService()
        service.result = page([hit("1"), hit("2")], total: 4)
        let model = self.model(service)
        model.reload()
        await settle()
        XCTAssertEqual(model.hits.count, 2)
        XCTAssertTrue(model.hasMore)

        // The second page repeats one row, as a page boundary that moved
        // between two requests would.
        service.result = FileSearchResult(total: 4, page: 2, pageSize: 30,
                                          hits: [hit("2"), hit("3"), hit("4")],
                                          facets: .empty)
        model.loadMore()
        await settle()
        XCTAssertEqual(model.hits.map(\.id), ["1", "2", "3", "4"])
        XCTAssertEqual(service.requests.last?.page, 2)
        XCTAssertFalse(model.hasMore)
    }

    /// A failed "load more" must not roll the page number forward, or the next
    /// attempt silently skips a page of results.
    func testAFailedLoadMoreDoesNotAdvanceThePage() async {
        let service = FilesStubService()
        service.result = page([hit("1")], total: 9)
        let model = self.model(service)
        model.reload()
        await settle()
        service.searchError = APIError.server(status: 500)
        model.loadMore()
        await settle()
        service.searchError = nil
        model.loadMore()
        await settle()
        XCTAssertEqual(service.requests.last?.page, 2)
        // The rows that were already there are still there.
        XCTAssertEqual(model.refreshFailure == nil, true)
    }

    func testNarrowingAccumulatesHistoryAndAdoptsTheServersFilters() async {
        let service = FilesStubService()
        service.result = page([hit("1")], total: 1)
        let model = self.model(service)
        model.reload()
        await settle()

        service.narrowing = FilesNarrowing(
            query: "tournament",
            filters: FileFilters(umbrellas: ["Robolabs"], kinds: [.sheet]),
            explanation: "Narrowed to spreadsheets in Robolabs.",
            result: page([hit("9")], total: 1))
        model.narrow("robolabs spreadsheets about tournaments")
        await settle()

        XCTAssertEqual(model.filters.umbrellas, ["Robolabs"])
        XCTAssertEqual(model.filters.kinds, [.sheet])
        XCTAssertEqual(model.explanation, "Narrowed to spreadsheets in Robolabs.")
        XCTAssertEqual(model.query, "tournament")
        XCTAssertEqual(model.hits.map(\.id), ["9"])
        XCTAssertEqual(model.history.count, 1)
        // The history records what was ASKED and what was in force when it was
        // asked - not the answer's own filters.
        XCTAssertEqual(model.history.first?.q, "robolabs spreadsheets about tournaments")
        XCTAssertTrue(model.history.first?.filters.isEmpty ?? false)

        service.narrowing = FilesNarrowing(
            query: "tournament",
            filters: FileFilters(umbrellas: ["Robolabs"], kinds: [.sheet],
                                 since: "2025-01-01", until: "2025-12-31"),
            explanation: "And only 2025.",
            result: page([], total: 0))
        model.narrow("2025 only")
        await settle()
        XCTAssertEqual(model.history.count, 2)
        // The SECOND call carries the first rung as context.
        XCTAssertEqual(service.narrowCalls.last?.history.count, 1)
        XCTAssertEqual(service.narrowCalls.last?.filters.kinds, [.sheet])
        XCTAssertEqual(model.filters.year, 2025)
    }

    /// A chip taken off by thumb ends the conversation: the explanation on
    /// screen described a filter set that no longer exists.
    func testRemovingAChipClearsTheExplanationAndTheHistory() async {
        let service = FilesStubService()
        service.result = page([hit("1")], total: 1)
        let model = self.model(service)
        service.narrowing = FilesNarrowing(
            query: "", filters: FileFilters(kinds: [.pdf]),
            explanation: "Narrowed to PDFs.", result: page([hit("1")], total: 1))
        model.narrow("pdfs")
        await settle()
        XCTAssertNotNil(model.explanation)

        let chip = try? XCTUnwrap(model.filters.chips.first)
        model.remove(chip!)
        await settle()
        XCTAssertNil(model.explanation)
        XCTAssertTrue(model.history.isEmpty)
        XCTAssertTrue(model.filters.isEmpty)
    }

    /// An answer's `files` payload replaces whatever the browser was showing,
    /// which is what "show me the Robolabs spreadsheets" asks for.
    func testAppliedPayloadReplacesTheListing() async {
        let service = FilesStubService()
        service.result = page([hit("1")], total: 1)
        let model = self.model(service)
        model.reload()
        await settle()

        service.result = page([hit("7"), hit("8")], total: 2)
        model.apply(payload: FilesPayload(
            query: "run sheet",
            filters: FileFilters(umbrellas: ["Robolabs"], kinds: [.sheet]),
            total: 2))
        await settle()
        XCTAssertEqual(model.query, "run sheet")
        XCTAssertEqual(model.filters.kinds, [.sheet])
        XCTAssertEqual(model.hits.map(\.id), ["7", "8"])
        XCTAssertEqual(service.requests.last?.q, "run sheet")
        XCTAssertEqual(service.requests.last?.page, 1)
    }

    func testPendingRouteIsTakenExactlyOnce() async {
        let service = FilesStubService()
        service.result = page([hit("1")], total: 1)
        let model = self.model(service)
        FilesRoute.record(FilesPayload(query: "cv",
                                       filters: FileFilters(kinds: [.pdf]), total: 1))
        model.takePendingRoute()
        await settle()
        let after = service.requests.count
        model.takePendingRoute()
        await settle()
        XCTAssertEqual(service.requests.count, after)
        XCTAssertEqual(model.filters.kinds, [.pdf])
    }

    /// Committing a query moves the sort to relevance, and clearing it moves
    /// back - an order the server cannot produce is not offered.
    func testCommittingAQuerySwitchesToRelevanceAndBack() async {
        let service = FilesStubService()
        service.result = page([], total: 0)
        let model = self.model(service)
        model.query = "resume"
        model.submitQuery()
        await settle()
        XCTAssertEqual(model.sort, .relevance)
        XCTAssertTrue(model.isSearching)

        model.query = ""
        model.submitQuery()
        await settle()
        XCTAssertEqual(model.sort, .mtimeDesc)
        XCTAssertFalse(model.isSearching)
    }

    func testCountLabelOnlyShowsAFractionWhileOneIsTrue() async {
        let service = FilesStubService()
        service.result = page([hit("1"), hit("2")], total: 2)
        let model = self.model(service)
        model.reload()
        await settle()
        XCTAssertEqual(model.countLabel, "2 files")

        service.result = page([hit("1")], total: 9)
        model.reload()
        await settle()
        XCTAssertEqual(model.countLabel, "1 of 9")
    }

    /// Lets the view model's detached work land. Several hops, because a
    /// reload spawns a task that awaits the service and then publishes.
    private func settle(_ hops: Int = 8) async {
        for _ in 0..<hops { await Task.yield() }
    }
}
