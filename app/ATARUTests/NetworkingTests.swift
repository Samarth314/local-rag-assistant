import XCTest
@testable import ATARU

/// Wire-format tests. The backend's shapes are fixed by the Python side, so
/// these pin the contract rather than the implementation.
final class DTODecodingTests: XCTestCase {

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try ATARUCoding.decoder.decode(type, from: Data(json.utf8))
    }

    func testDocumentSummaryDecodesSnakeCaseAndUnixTimestamps() throws {
        let dto = try decode(DTO.DocumentSummary.self, """
        {"id":"abc","title":"Notes.md","path":"/docs/notes.md","category":"work",
         "file_type":"MD","size_bytes":2048,"modified_at":1700000000.0,
         "indexed_at":1700000900.0,"excerpt":"hello","chunk_count":3,
         "tags":["a"],"previewable":true}
        """)
        let document = dto.domain
        XCTAssertEqual(document.title, "Notes.md")
        XCTAssertEqual(document.fileType, "md")          // normalised to lowercase
        XCTAssertEqual(document.sizeBytes, 2048)
        XCTAssertEqual(document.modifiedAt, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(document.category, .work)
        XCTAssertTrue(document.previewable)
    }

    func testMissingTimestampsBecomeNilNotNineteenSeventy() throws {
        // Entries indexed before ATARU recorded ingest times genuinely have
        // none; rendering those as 1 Jan 1970 would be a lie, not a default.
        let dto = try decode(DTO.DocumentSummary.self, """
        {"id":"a","title":"t","path":"p","category":"work","file_type":"md",
         "size_bytes":null,"modified_at":null,"indexed_at":null,"excerpt":null,
         "chunk_count":null,"tags":null,"previewable":null}
        """)
        XCTAssertNil(dto.domain.modifiedAt)
        XCTAssertNil(dto.domain.indexedAt)
        XCTAssertEqual(dto.domain.excerpt, "")
        XCTAssertEqual(dto.domain.tags, [])
        XCTAssertFalse(dto.domain.previewable)
    }

    func testZeroTimestampIsTreatedAsAbsent() throws {
        let dto = try decode(DTO.DocumentSummary.self, """
        {"id":"a","title":"t","path":"p","category":"work","file_type":"md",
         "modified_at":0}
        """)
        XCTAssertNil(dto.domain.modifiedAt)
    }

    func testUnknownCategoryFallsBackInsteadOfFailingTheDecode() throws {
        // One unrecognised category from a newer server must not blank the
        // whole library.
        let dto = try decode(DTO.DocumentSummary.self, """
        {"id":"a","title":"t","path":"p","category":"legal","file_type":"md"}
        """)
        XCTAssertEqual(dto.domain.category, .personal)
    }

    func testDocumentListCarriesCountsAndTotals() throws {
        let dto = try decode(DTO.DocumentList.self, """
        {"documents":[],"total":2,"indexed_total":9,
         "categories":{"work":4,"health":5}}
        """)
        let page = dto.domain
        XCTAssertEqual(page.total, 2)
        XCTAssertEqual(page.indexedTotal, 9)
        XCTAssertEqual(page.categoryCounts[.work], 4)
        XCTAssertEqual(page.categoryCounts[.health], 5)
        // `all` reports the vault, not the filtered page.
        XCTAssertEqual(page.categoryCounts[.all], 9)
    }
}

final class EndpointBuilderTests: XCTestCase {

    private var builder: EndpointBuilder {
        EndpointBuilder(baseURL: URL(string: "http://100.64.0.1:8000")!)
    }

    func testRoutesSitAtTheRootByDefault() {
        XCTAssertEqual(builder.health?.absoluteString, "http://100.64.0.1:8000/health")
    }

    func testTrailingSlashesInTheBaseAreTolerated() {
        let messy = EndpointBuilder(baseURL: URL(string: "http://host:8000///")!)
        XCTAssertEqual(messy.health?.absoluteString, "http://host:8000/health")
    }

    func testApiVersionInsertsAPrefixWhenSet() {
        let versioned = EndpointBuilder(baseURL: URL(string: "http://host")!, apiVersion: "v1")
        XCTAssertEqual(versioned.health?.absoluteString, "http://host/api/v1/health")
    }

    func testQuestionsArePercentEncoded() {
        let url = builder.speak("what's the FHA rate?")
        XCTAssertNotNil(url)
        XCTAssertFalse(url!.absoluteString.contains(" "))
        XCTAssertTrue(url!.absoluteString.contains("/voice/speak"))
    }

    func testCategoryIsOmittedWhenAll() {
        XCTAssertEqual(builder.documents(query: nil, category: .all)?.absoluteString,
                       "http://100.64.0.1:8000/documents")
        XCTAssertTrue(builder.documents(query: nil, category: .health)!
            .absoluteString.contains("category=health"))
    }

    func testDocumentIdsCannotEscapeTheirPathSegment() throws {
        // Ids are server-assigned hashes, but the client must not be the thing
        // that trusts them: a traversal-shaped id has to stay one segment.
        //
        // The assertion is on `absoluteString`, which is what actually goes on
        // the wire. `URL.path` percent-DECODES, so it would show the traversal
        // back even when the request is correctly escaped — checking it would
        // fail a URL that is in fact safe.
        let url = try XCTUnwrap(builder.documentContent("../../etc/passwd"))
        XCTAssertFalse(url.absoluteString.contains(".."))
        XCTAssertFalse(url.absoluteString.contains("/etc/"))
        XCTAssertTrue(url.absoluteString.hasPrefix("http://100.64.0.1:8000/documents/"))
        XCTAssertTrue(url.absoluteString.hasSuffix("/content"))
    }
}

final class BaseURLValidationTests: XCTestCase {

    func testHttpsIsAlwaysAccepted() {
        XCTAssertTrue(AppConfiguration.validate("https://ataru.example.ts.net").isValid)
    }

    func testEmptyAndMalformedAreDistinguished() {
        XCTAssertEqual(AppConfiguration.validate(""), .empty)
        XCTAssertEqual(AppConfiguration.validate("ftp://host"), .malformed)
    }

    func testTailscaleAndPrivateRangesCountAsPrivate() {
        XCTAssertTrue(AppConfiguration.isPrivateHost("100.64.0.1"))      // CGNAT, Tailscale's range
        XCTAssertTrue(AppConfiguration.isPrivateHost("192.168.1.10"))
        XCTAssertTrue(AppConfiguration.isPrivateHost("orin.local"))
        XCTAssertFalse(AppConfiguration.isPrivateHost("example.com"))
        XCTAssertFalse(AppConfiguration.isPrivateHost("8.8.8.8"))
    }
}

final class DownloadNamingTests: XCTestCase {

    func testTitlesCannotSteerTheWriteOutOfTheScratchDirectory() {
        // The title is server-supplied, so it is untrusted input to a file
        // write no matter how benign it usually is.
        //
        // The invariant is that the result is a *leaf name*: no separator, and
        // not a relative-path component. An interior ".." with no separator
        // around it is an odd filename, not a traversal, so it is allowed to
        // survive rather than mangling legitimate names like "v1..final.pdf".
        for hostile in ["../../evil.txt", "a/b/c.pdf", "..\\..\\evil", "/etc/passwd"] {
            let safe = DocumentDownloadStore.sanitize(hostile)
            XCTAssertFalse(safe.contains("/"), "separator survived in \(safe)")
            XCTAssertFalse(safe.contains("\\"), "separator survived in \(safe)")
            XCTAssertNotEqual(safe, "..")
            XCTAssertNotEqual(safe, ".")
        }
        XCTAssertEqual(DocumentDownloadStore.sanitize("..."), "document")
        XCTAssertEqual(DocumentDownloadStore.sanitize(""), "document")
        XCTAssertEqual(DocumentDownloadStore.sanitize("   "), "document")
    }

    func testOrdinaryNamesSurviveIntact() {
        // The filename is what a recipient sees in Mail or AirDrop, so it
        // should stay readable rather than becoming an opaque id.
        XCTAssertEqual(DocumentDownloadStore.sanitize("Quarterly Budget.pdf"),
                       "Quarterly Budget.pdf")
    }

    func testContentDispositionFilenameIsPreferredOverTheURL() throws {
        let response = HTTPURLResponse(
            url: URL(string: "http://host/documents/abc123/content")!,
            statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Disposition": "inline; filename=\"Lab Panel.pdf\""]
        )!
        XCTAssertEqual(LiveATARUService.filename(from: response), "Lab Panel.pdf")
    }
}

// MARK: - What the app says when it cannot reach the server

/// The banner is the whole of the app's connectivity story, so its copy is
/// worth pinning.
///
/// THE TWO OFFLINE STATES ARE NOT THE SAME STATE. The backend lives on the
/// tailnet and nowhere else: a phone with perfectly good Wi-Fi that cannot
/// reach ATARU is, almost always, a phone with Tailscale switched off - and
/// that is something the user can fix in ten seconds if anything tells them
/// to. A phone in airplane mode cannot be helped by that advice, and offering
/// it is worse than saying nothing. The app used to render both as "Offline",
/// which is wrong about the first and unhelpful about the second.
final class FreshnessCopyTests: XCTestCase {

    func testAReachablePhoneWithAnUnreachableServerIsToldAboutTailscale() {
        let message = DataFreshness.unreachable(nil).bannerMessage
        XCTAssertEqual(message,
                       "Can't reach ATARU. Away from home? "
                       + "Turn on Tailscale - I'll reconnect automatically.")
    }

    func testTheLastSuccessfulSyncIsShownWhenThereIsOne() {
        let message = DataFreshness.unreachable(Date(timeIntervalSinceNow: -3600)).bannerMessage
        XCTAssertNotNil(message)
        XCTAssertTrue(message!.contains("Last synced"),
                      "stale content has to say how stale")
    }

    /// No path at all: nothing about Tailscale would help, so it is not
    /// mentioned.
    func testNoNetworkPathSaysSoAndNothingElse() {
        let message = DataFreshness.noNetwork.bannerMessage
        XCTAssertEqual(message, "No network connection.")
        XCTAssertFalse(message!.contains("Tailscale"))
    }

    func testLiveDrawsNoBannerAtAll() {
        XCTAssertNil(DataFreshness.live.bannerMessage)
        XCTAssertFalse(DataFreshness.live.isOffline)
    }

    func testEveryOfflineStateReportsItselfAsOffline() {
        XCTAssertTrue(DataFreshness.unreachable(nil).isOffline)
        XCTAssertTrue(DataFreshness.noNetwork.isOffline)
        XCTAssertTrue(DataFreshness.offline(nil).isOffline)
        // Cached content over a working connection is not an outage.
        XCTAssertFalse(DataFreshness.stale(Date()).isOffline)
        XCTAssertFalse(DataFreshness.demo.isOffline)
    }
}
