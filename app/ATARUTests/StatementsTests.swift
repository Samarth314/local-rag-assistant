import XCTest
@testable import ATARU

/// The statement checklist: what it decodes, how it orders itself, when it
/// nags, and - the one that is a security claim rather than a behaviour - where
/// its "Log in" buttons are allowed to go.
final class StatementsTests: XCTestCase {

    // MARK: - The contract

    /// The payload exactly as the finance service documents it, plus the two
    /// things a real one does that a happy-path fixture never would: a status
    /// string this build has never heard of, and a source that has never filed
    /// anything.
    private let contract = """
    {
      "as_of": "2026-09-08",
      "sitting_day": 10,
      "sitting": {"month": "2026-09", "label": "September 2026 sitting",
                  "date": "2026-09-10", "is_today_or_past": false},
      "sources": [
        {"id": "wellsfargo-checking", "label": "Wells Fargo checking",
         "login_url": "https://www.wellsfargo.com/",
         "close_day": 7, "posts_by_day": 10, "target_month": "2026-09",
         "status": "not_posted_yet",
         "latest_period_end": "2026-06-05", "gaps": ["2026-07", "2026-08"]},
        {"id": "amex-card-monthly", "label": "Amex card",
         "login_url": "https://www.americanexpress.com/",
         "target_month": "2026-09", "status": "missing",
         "latest_period_end": null},
        {"id": "fidelity-statement", "label": "Fidelity",
         "login_url": "https://www.fidelity.com/",
         "target_month": "2026-09", "status": "quarantined"}
      ],
      "missing": ["amex-card-monthly"],
      "not_posted_yet": ["wellsfargo-checking"],
      "complete": false,
      "n_missing": 4,
      "store": {"path": "records/finances/statements", "ok": true, "reason": null}
    }
    """

    private func decoded(_ json: String) throws -> StatementsDTO {
        try JSONDecoder().decode(StatementsDTO.self, from: Data(json.utf8))
    }

    func testTheDocumentedPayloadDecodes() throws {
        let payload = try decoded(contract)
        XCTAssertEqual(payload.as_of, "2026-09-08")
        XCTAssertEqual(payload.sitting_day, 10)
        XCTAssertEqual(payload.sitting?.label, "September 2026 sitting")
        XCTAssertEqual(payload.sitting?.is_today_or_past, false)
        XCTAssertEqual(payload.sources?.count, 3)
        XCTAssertEqual(payload.missing, ["amex-card-monthly"])
        XCTAssertEqual(payload.not_posted_yet, ["wellsfargo-checking"])
        XCTAssertEqual(payload.complete, false)
        XCTAssertEqual(payload.n_missing, 4)
        XCTAssertEqual(payload.store?.ok, true)
        XCTAssertNil(payload.store?.reason)

        let wells = try XCTUnwrap(payload.sources?.first)
        XCTAssertEqual(wells.state, .not_posted_yet)
        XCTAssertEqual(wells.close_day, 7)
        XCTAssertEqual(wells.posts_by_day, 10)
        XCTAssertEqual(wells.gaps, ["2026-07", "2026-08"])
    }

    /// The service may learn a fourth state before this app does. That has to
    /// degrade to one unreadable row, never to a refused document.
    func testAnUnknownStatusStringBecomesUnknownRatherThanADecodeFailure() throws {
        let payload = try decoded(contract)
        let fidelity = try XCTUnwrap(
            payload.sources?.first { $0.id == "fidelity-statement" })
        XCTAssertEqual(fidelity.state, .unknown)
        XCTAssertEqual(fidelity.state.word, "Unknown")
    }

    func testANullLatestPeriodEndIsAnAbsenceAndNotAFailure() throws {
        let payload = try decoded(contract)
        let amex = try XCTUnwrap(
            payload.sources?.first { $0.id == "amex-card-monthly" })
        XCTAssertNil(amex.latest_period_end)
        // And the optional keys it simply does not carry.
        XCTAssertNil(amex.close_day)
        XCTAssertNil(amex.posts_by_day)
        XCTAssertNil(amex.gaps)
    }

    /// Absent keys are absent, not fatal. A degraded answer still draws.
    func testAPayloadStrippedToNothingStillDecodes() throws {
        let payload = try decoded("{}")
        XCTAssertNil(payload.sources)
        XCTAssertEqual(payload.orderedSources, [])
        XCTAssertEqual(payload.missingCount, 0)
        XCTAssertFalse(payload.showsNudge)
        // No `store` key at all is not the same claim as `store.ok == false`.
        XCTAssertFalse(payload.storeIsBroken)
    }

    func testAStatusThatIsNotEvenAStringIsUnknown() throws {
        let payload = try decoded("""
        {"sources": [{"id": "x", "label": "X", "status": 7}]}
        """)
        XCTAssertEqual(payload.sources?.first?.state, .unknown)
    }

    func testABrokenStoreIsReportedAsBroken() throws {
        let payload = try decoded("""
        {"store": {"path": "p", "ok": false, "reason": "index is locked"}}
        """)
        XCTAssertTrue(payload.storeIsBroken)
        XCTAssertEqual(payload.store?.reason, "index is locked")
    }

    // MARK: - Order

    /// Missing first, then what has not posted, then what is filed, then what
    /// the app cannot describe. That is the order the job is worked in.
    func testRowsSortMissingThenNotPostedThenPresentThenUnknown() throws {
        let payload = try decoded("""
        {"sources": [
          {"id": "d", "label": "Delta", "status": "present"},
          {"id": "e", "label": "Echo", "status": "kumquat"},
          {"id": "a", "label": "Alpha", "status": "not_posted_yet"},
          {"id": "b", "label": "Bravo", "status": "missing"},
          {"id": "c", "label": "Charlie", "status": "missing"}
        ]}
        """)
        XCTAssertEqual(payload.orderedSources.map(\.id),
                       ["b", "c", "a", "d", "e"])
        XCTAssertEqual(payload.orderedSources.map(\.state),
                       [.missing, .missing, .not_posted_yet, .present, .unknown])
    }

    /// The list is refetched every few seconds during an ingest, so equal rows
    /// must not swap places under a thumb.
    func testOrderingIsStableForRowsInTheSameState() throws {
        let json = """
        {"sources": [
          {"id": "z", "label": "Same", "status": "missing"},
          {"id": "a", "label": "Same", "status": "missing"},
          {"id": "m", "label": "Same", "status": "missing"}
        ]}
        """
        let first = try decoded(json).orderedSources.map(\.id)
        let second = try decoded(json).orderedSources.map(\.id)
        XCTAssertEqual(first, ["a", "m", "z"])
        XCTAssertEqual(first, second)
    }

    func testARowWithNoLabelAtAllStillHasSomethingToDraw() throws {
        let payload = try decoded("""
        {"sources": [{"id": "only-an-id", "status": "missing"}, {"status": "missing"}]}
        """)
        XCTAssertEqual(payload.orderedSources.map(\.displayLabel),
                       ["only-an-id", "Unnamed account"])
    }

    // MARK: - The nudge

    /// Both halves, and nothing else. Something missing on the 3rd is not yet
    /// a problem; on the sitting day it is the whole job.
    func testTheNudgeNeedsBothAMissingStatementAndTheSittingDay() {
        func nudges(missing: Int, sittingReached: Bool) -> Bool {
            let json = """
            {"n_missing": \(missing),
             "sitting": {"month": "2026-09", "is_today_or_past": \(sittingReached)}}
            """
            return (try? decoded(json))?.showsNudge ?? false
        }
        XCTAssertTrue(nudges(missing: 4, sittingReached: true))
        XCTAssertFalse(nudges(missing: 4, sittingReached: false))
        XCTAssertFalse(nudges(missing: 0, sittingReached: true))
        XCTAssertFalse(nudges(missing: 0, sittingReached: false))
    }

    /// A payload with no sitting block at all must not nag: "is it the day"
    /// is unanswered, and unanswered is not yes.
    func testNoSittingBlockMeansNoNudge() throws {
        XCTAssertFalse(try decoded("{\"n_missing\": 3}").showsNudge)
    }

    func testTheStateLineSaysWhichOfTheThreeSituationsThisIs() throws {
        XCTAssertEqual(try decoded("{\"n_missing\": 4}").stateLine, "4 missing")
        XCTAssertEqual(
            try decoded("{\"n_missing\": 0, \"sitting_day\": 10, \"not_posted_yet\": [\"a\"]}")
                .stateLine,
            "Not all posted yet - the 10th is the day")
        XCTAssertEqual(try decoded("{\"n_missing\": 0, \"complete\": true}").stateLine,
                       "Complete")
    }

    func testTheSittingMonthIsNamedForTheNudgeAndNeverGuessed() throws {
        XCTAssertEqual(try decoded("{\"sitting\": {\"month\": \"2026-09\"}}").sittingMonthName,
                       DateFormatter().monthSymbols[8])
        XCTAssertNil(try decoded("{\"sitting\": {\"month\": \"2026-13\"}}").sittingMonthName)
        XCTAssertNil(try decoded("{\"sitting\": {\"month\": \"nonsense\"}}").sittingMonthName)
        XCTAssertNil(try decoded("{}").sittingMonthName)
    }

    // MARK: - Where "Log in" is allowed to go

    /// THE SECURITY CLAIM OF THIS PAGE. A bank login is exactly the link worth
    /// spoofing, so the payload's `login_url` is matched against this table
    /// rather than opened, and no other host can ever be reached from here.
    func testTheOnlyLoginHostsAreTheSixCanonicalOnes() {
        XCTAssertEqual(StatementLogin.catalog.count, 6)
        XCTAssertEqual(StatementLogin.catalog.map(\.url.absoluteString),
                       ["https://www.wellsfargo.com/",
                        "https://www.americanexpress.com/",
                        "https://www.americanexpress.com/",
                        "https://www.capitalone.com/",
                        "https://www.fidelity.com/",
                        "https://robinhood.com/"])
        XCTAssertEqual(StatementLogin.allowedHosts,
                       ["www.wellsfargo.com", "www.americanexpress.com",
                        "www.capitalone.com", "www.fidelity.com", "robinhood.com"])
        // Root domains only: no path, query or fragment on any of them.
        for known in StatementLogin.catalog {
            let components = URLComponents(url: known.url, resolvingAgainstBaseURL: false)
            XCTAssertEqual(known.url.scheme, "https", "\(known.id) is not https")
            XCTAssertEqual(components?.path, "/", "\(known.id) carries a path")
            XCTAssertNil(components?.query, "\(known.id) carries a query")
            XCTAssertNil(components?.fragment, "\(known.id) carries a fragment")
        }
    }

    func testEveryDocumentedSourceIdResolvesToItsCanonicalRoot() {
        let expected = ["wellsfargo-checking": "https://www.wellsfargo.com/",
                        "amex-card-monthly": "https://www.americanexpress.com/",
                        "amex-savings-csv": "https://www.americanexpress.com/",
                        "capitalone-monthly": "https://www.capitalone.com/",
                        "fidelity-statement": "https://www.fidelity.com/",
                        "robinhood-csv": "https://robinhood.com/"]
        for (id, url) in expected {
            XCTAssertEqual(
                StatementLogin.url(forID: id, advertised: nil)?.absoluteString, url)
        }
    }

    /// The id wins over whatever the payload advertises, so a compromised or
    /// mistaken service cannot redirect a known row.
    func testAKnownIdIgnoresTheAdvertisedURLEntirely() {
        XCTAssertEqual(
            StatementLogin.url(forID: "wellsfargo-checking",
                               advertised: "https://wellsfargo.evil.example/login")?
                .absoluteString,
            "https://www.wellsfargo.com/")
    }

    /// An unknown id may still be placed by its host - but what opens is the
    /// canonical root, never the advertised URL, so a path or query cannot ride
    /// along.
    func testAnUnknownIdIsPlacedByHostAndStrippedToTheRoot() {
        XCTAssertEqual(
            StatementLogin.url(forID: "brand-new-account",
                               advertised: "https://www.fidelity.com/login?next=/x")?
                .absoluteString,
            "https://www.fidelity.com/")
    }

    func testAnythingOffTheAllowlistGetsNoButtonAtAll() {
        for advertised in ["https://wellsfargo.com.evil.example/",
                           "https://phish.example/wellsfargo",
                           "https://sub.www.fidelity.com/",
                           "https://americanexpress.com/",
                           "not a url",
                           ""] {
            XCTAssertNil(StatementLogin.url(forID: "unheard-of", advertised: advertised),
                         "\(advertised) was offered as a login link")
        }
        XCTAssertNil(StatementLogin.url(forID: nil, advertised: nil))
    }

    /// Every login link the page can produce, from any payload, lands on an
    /// allowed host. This is the assertion that would fail if a future edit
    /// started trusting `login_url`.
    func testNoPayloadCanProduceALinkToAnyOtherHost() throws {
        let hostile = try decoded("""
        {"sources": [
          {"id": "wellsfargo-checking", "login_url": "https://evil.example/"},
          {"id": "not-a-real-source", "login_url": "https://evil.example/"},
          {"id": "robinhood-csv", "login_url": "http://robinhood.com.evil.example/"},
          {"login_url": "https://www.capitalone.com/deep/link?x=1"}
        ]}
        """)
        let resolved = hostile.orderedSources.compactMap(StatementLogin.url(for:))
        XCTAssertEqual(resolved.count, 3, "an unknown source produced a link")
        for url in resolved {
            XCTAssertTrue(StatementLogin.allowedHosts.contains(url.host ?? ""),
                          "\(url) escaped the allowlist")
            XCTAssertEqual(url.path, "/")
        }
    }

    // MARK: - Uploading

    func testTheMultipartBodyCarriesEveryFileWithItsOwnContentType() {
        let parts = [
            MultipartBody.Part(filename: "amex-2026-09.pdf",
                               contentType: MultipartBody.contentType(
                                forFilename: "amex-2026-09.pdf"),
                               data: Data("%PDF-1.7 first".utf8)),
            MultipartBody.Part(filename: "robinhood-2026-09.csv",
                               contentType: MultipartBody.contentType(
                                forFilename: "robinhood-2026-09.csv"),
                               data: Data("date,amount\n2026-09-01,12".utf8)),
        ]
        let boundary = "test-boundary"
        let body = MultipartBody.encode(parts: parts, boundary: boundary)
        let text = String(decoding: body, as: UTF8.self)

        XCTAssertTrue(text.contains(
            "Content-Disposition: form-data; name=\"files\"; filename=\"amex-2026-09.pdf\""))
        XCTAssertTrue(text.contains("Content-Type: application/pdf"))
        XCTAssertTrue(text.contains("%PDF-1.7 first"))

        XCTAssertTrue(text.contains(
            "Content-Disposition: form-data; name=\"files\"; filename=\"robinhood-2026-09.csv\""))
        XCTAssertTrue(text.contains("Content-Type: text/csv"))
        XCTAssertTrue(text.contains("date,amount"))

        // Two opening boundaries and one closing one, in that shape.
        XCTAssertEqual(text.components(separatedBy: "--\(boundary)\r\n").count - 1, 2)
        XCTAssertTrue(text.hasSuffix("--\(boundary)--\r\n"))
        // Headers end with a blank line, or the server reads the body as more
        // headers. This is the failure that returns a bare 400.
        XCTAssertTrue(text.contains("Content-Type: application/pdf\r\n\r\n%PDF"))
    }

    func testContentTypeComesFromTheExtensionAndNeverGuesses() {
        XCTAssertEqual(MultipartBody.contentType(forFilename: "a.pdf"), "application/pdf")
        XCTAssertEqual(MultipartBody.contentType(forFilename: "A.PDF"), "application/pdf")
        XCTAssertEqual(MultipartBody.contentType(forFilename: "b.csv"), "text/csv")
        XCTAssertEqual(MultipartBody.contentType(forFilename: "c.txt"),
                       "application/octet-stream")
        XCTAssertEqual(MultipartBody.contentType(forFilename: "no-extension"),
                       "application/octet-stream")
    }

    /// A filename comes from the Files app, so it is whatever a person typed.
    /// A quote in it would end the header early.
    func testAQuoteInAFilenameCannotBreakTheHeader() {
        let body = MultipartBody.encode(
            parts: [MultipartBody.Part(filename: "a\"; name=\"evil\r\n.pdf",
                                       contentType: "application/pdf",
                                       data: Data())],
            boundary: "b")
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertFalse(text.contains("name=\"evil"))
        XCTAssertEqual(text.components(separatedBy: "filename=").count - 1, 1)
    }

    func testAnUploadAnswerDecodesIncludingTheRejections() throws {
        let result = try JSONDecoder().decode(StatementsUploadDTO.self, from: Data("""
        {"accepted": [{"name": "a.pdf", "bytes": 12}],
         "rejected": [{"name": "b.png", "reason": "not a pdf or csv"}],
         "inbox": "inbox/"}
        """.utf8))
        XCTAssertEqual(result.accepted?.first?.name, "a.pdf")
        XCTAssertEqual(result.accepted?.first?.bytes, 12)
        XCTAssertEqual(result.rejected?.first?.reason, "not a pdf or csv")
        XCTAssertEqual(result.inbox, "inbox/")
        // And the degraded shape.
        XCTAssertNoThrow(try JSONDecoder().decode(StatementsUploadDTO.self,
                                                  from: Data("{}".utf8)))
    }

    // MARK: - Demo

    /// The fixture has to exercise every state the page draws, or Demo proves
    /// nothing about it.
    func testTheDemoFixtureCoversEveryStateThePageCanDraw() {
        let payload = DemoFixtures.statements()
        let states = payload.orderedSources.map(\.state)
        XCTAssertEqual(states.filter { $0 == .missing }.count, 2)
        XCTAssertEqual(states.filter { $0 == .not_posted_yet }.count, 1)
        XCTAssertEqual(states.filter { $0 == .present }.count, 3)
        XCTAssertEqual(payload.missingCount, 2)
        XCTAssertTrue(payload.showsNudge, "the nudge is unreachable in Demo")
        XCTAssertTrue(payload.orderedSources.contains { !($0.gaps ?? []).isEmpty },
                      "no fixture row exercises the gaps line")
        // Demo fixtures are synthetic, but the links still go through the
        // allowlist like everything else.
        for source in payload.orderedSources {
            let host = StatementLogin.url(for: source)?.host ?? ""
            XCTAssertTrue(StatementLogin.allowedHosts.contains(host),
                          "\(source.displayLabel) has no allowed login link")
        }
    }
}

// MARK: - The launcher, and the pager that absorbed a tile

final class FinancePagerTests: XCTestCase {

    /// Cards has no orb any more. Asserted against the enum the launcher and
    /// the accessibility actions are BOTH built from, so this covers the fan
    /// and the rotor together.
    func testTheLauncherHasNoCardsTile() {
        XCTAssertFalse(HomeTile.allCases.contains { $0.rawValue == "cards" })
        XCTAssertFalse(HomeTile.allCases.contains { $0.title == "Cards" })
        XCTAssertNil(HomeTile(rawValue: "cards"))
        // And the destination that absorbed it is still there.
        XCTAssertTrue(HomeTile.allCases.contains(.finance))
    }

    /// Nothing else moved. The fan's geometry is derived from the count, so
    /// this is the only claim about the set that a removal could break.
    func testEveryOtherTileSurvivedTheRemoval() {
        XCTAssertEqual(HomeTile.allCases.map(\.rawValue),
                       ["assistant", "plan", "notes", "finance", "health",
                        "journal", "documents", "home", "workspaces",
                        "morning", "settings", "status", "passwords", "media",
                        "music", "whiteboard", "remote"])
    }

    func testFinanceAdvertisesItsNewScope() {
        XCTAssertEqual(HomeTile.finance.kind, "Spending · cards · statements")
    }

    func testFinanceHasExactlyThreePages() {
        XCTAssertEqual(FinancePage.allCases.count, 3)
        XCTAssertEqual(FinancePage.allCases.map(\.id),
                       ["overview", "cards", "statements"])
        XCTAssertEqual(FinancePage.allCases.map(\.title),
                       ["Overview", "Cards", "Statements"])
    }

    /// A request for the retired tile lands on page two rather than nowhere.
    func testTheRetiredCardsNameRoutesToTheCardsPage() {
        XCTAssertEqual(FinanceRoute.retiredCardsTile, "cards")
        XCTAssertNil(FinanceRoute.take(), "a route was left behind by another test")
        FinanceRoute.record(.cards)
        XCTAssertEqual(FinanceRoute.take(), .cards)
        // Taken exactly once, like every other pending route in the app.
        XCTAssertNil(FinanceRoute.take())
    }
}
