import XCTest
@testable import ATARU

/// Who gets the token, and who does not.
///
/// This is the security claim in `ATARUAuth` written down somewhere a change
/// has to get past. The interesting direction is the negative one: a bearer
/// token stamped onto whatever URL a caller passes is how credentials leak,
/// and the tile fetchers take a URL from a builder rather than a constant.
final class ATARUAuthTests: XCTestCase {

    private func url(_ string: String) -> URL {
        URL(string: string)!
    }

    // MARK: - Trust

    func testTheConfiguredBackendIsTrusted() {
        XCTAssertTrue(ATARUAuth.isTrusted(url("http://100.106.109.31:8000/api/plan"),
                                          configuredHost: "100.106.109.31"))
    }

    func testTheAtaruDomainAndItsSubdomainsAreTrusted() {
        // The tiles resolve to these, and they are not the configured host.
        for host in ["ataru.aryasasikumar.com",
                     "home.ataru.aryasasikumar.com",
                     "dash.ataru.aryasasikumar.com",
                     "journal.ataru.aryasasikumar.com",
                     "dev.ataru.aryasasikumar.com"] {
            XCTAssertTrue(ATARUAuth.isTrusted(url("https://\(host)/api/launcher"),
                                              configuredHost: nil),
                          "\(host) should be trusted")
        }
    }

    func testAnyoneElseIsNot() {
        for host in ["example.com",
                     "evil.com",
                     // The suffix check must be on a DOT boundary: without it
                     // this reads as "ends with ataru.aryasasikumar.com" and
                     // hands the token to somebody else's domain.
                     "notataru.aryasasikumar.com",
                     "ataru.aryasasikumar.com.evil.net",
                     "aryasasikumar.com"] {
            XCTAssertFalse(ATARUAuth.isTrusted(url("https://\(host)/api/plan"),
                                               configuredHost: "100.106.109.31"),
                           "\(host) must not receive the token")
        }
    }

    func testATrailingRootDotIsStillTheSameHost() {
        XCTAssertTrue(ATARUAuth.isTrusted(url("https://home.ataru.aryasasikumar.com./x"),
                                          configuredHost: nil))
    }

    func testAURLWithNoHostIsNotTrusted() {
        XCTAssertFalse(ATARUAuth.isTrusted(url("file:///etc/passwd"),
                                           configuredHost: "100.106.109.31"))
    }

    // MARK: - Stamping

    /// Restores the globals, so one test cannot leave a token armed for the
    /// next one.
    private func withAuth(host: String?, token: String?,
                          _ body: () -> Void) {
        let previousToken = ATARUAuth.tokenProvider
        let previousHost = ATARUAuth.configuredHost
        defer {
            ATARUAuth.tokenProvider = previousToken
            ATARUAuth.configuredHost = previousHost
        }
        ATARUAuth.configure(baseURL: host.flatMap { URL(string: "http://\($0)") },
                            tokenProvider: { token })
        body()
    }

    private func header(for string: String) -> String? {
        var request = URLRequest(url: url(string))
        ATARUAuth.stamp(&request)
        return request.value(forHTTPHeaderField: "Authorization")
    }

    func testATrustedRequestCarriesTheBearerToken() {
        withAuth(host: "100.106.109.31", token: "sekret") {
            XCTAssertEqual(header(for: "http://100.106.109.31:8000/api/plan"),
                           "Bearer sekret")
        }
    }

    func testATileHostCarriesItToo() {
        // The whole point of the change: these went out bare.
        withAuth(host: "100.106.109.31", token: "sekret") {
            XCTAssertEqual(header(for: "https://home.ataru.aryasasikumar.com/api/home"),
                           "Bearer sekret")
        }
    }

    func testAnUntrustedHostGetsNothing() {
        withAuth(host: "100.106.109.31", token: "sekret") {
            XCTAssertNil(header(for: "https://evil.com/api/plan"))
        }
    }

    func testNoTokenMeansNoHeaderRatherThanAnEmptyOne() {
        // An empty bearer is a malformed credential, not an absent one, and a
        // server enforcing auth will treat the two differently.
        withAuth(host: "100.106.109.31", token: "") {
            XCTAssertNil(header(for: "http://100.106.109.31:8000/api/plan"))
        }
        withAuth(host: "100.106.109.31", token: nil) {
            XCTAssertNil(header(for: "http://100.106.109.31:8000/api/plan"))
        }
    }

    func testDemoSendsNothingAnywhere() {
        // rebuildService clears the provider in Demo; nothing configured must
        // mean nothing stamped, including at the ataru domain.
        withAuth(host: nil, token: nil) {
            XCTAssertNil(header(for: "https://home.ataru.aryasasikumar.com/api/home"))
        }
    }
}
