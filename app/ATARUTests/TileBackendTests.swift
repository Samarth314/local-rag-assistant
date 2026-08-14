import XCTest
@testable import ATARU

/// Which backend the tiles read from, which is a correctness question and not
/// a cosmetic one.
///
/// Getting this wrong in the dev direction is loud - production data on a page
/// expecting fixtures. Getting it wrong in the PRODUCTION direction is silent:
/// every tile serves the dev twin's invented numbers while looking exactly
/// like the real thing, and Finance and Health are two of those tiles. So the
/// cases that matter most below are the ones asserting `false`.
final class TileBackendTests: XCTestCase {

    // MARK: - The dev twin

    func testTheDevTwinIsRecognised() {
        for url in ["https://dev.ataru.aryasasikumar.com",
                    "https://dev.ataru.aryasasikumar.com/",
                    "https://dev.ataru.aryasasikumar.com/chat",
                    "https://dev.ataru.aryasasikumar.com:8443/chat",
                    "http://dev.ataru.aryasasikumar.com",
                    // Hosts are case-insensitive, and the settings field takes
                    // whatever was typed.
                    "https://DEV.Ataru.AryaSasikumar.com",
                    // A fully-qualified name may carry the root dot.
                    "https://dev.ataru.aryasasikumar.com./chat",
                    // No scheme: the settings field does not insist on one.
                    "dev.ataru.aryasasikumar.com",
                    "dev.ataru.aryasasikumar.com/chat",
                    "  https://dev.ataru.aryasasikumar.com  "] {
            XCTAssertTrue(TileBackend.isDevBackend(url),
                          "\(url) is the dev twin and was read as production")
        }
    }

    // MARK: - Production

    func testTheRealProductionHostsAreNotTheDevTwin() {
        // The two that are actually configured - see Config.xcconfig.
        for url in ["https://chat.ataru.aryasasikumar.com",
                    "https://ataru.aryasasikumar.com",
                    "https://home.ataru.aryasasikumar.com",
                    "https://dash.ataru.aryasasikumar.com"] {
            XCTAssertFalse(TileBackend.isDevBackend(url),
                           "\(url) is production and would have served fixtures")
        }
    }

    /// The bug this replaced: `contains("dev.")`. Every one of these was true
    /// under the old check, and every one of them is a production URL.
    func testAProductionURLThatMerelyContainsDevIsStillProduction() {
        for url in ["https://mydev.company.com",
                    "https://ataru.aryasasikumar.com.dev.cdn.example",
                    "https://ataru.aryasasikumar.com/dev.html",
                    "https://ataru.aryasasikumar.com/chat?flag=dev.x",
                    "https://ataru.aryasasikumar.com#dev.notes",
                    "https://notdev.ataru.aryasasikumar.com",
                    "https://dev.ataru.aryasasikumar.com.evil.example"] {
            XCTAssertFalse(TileBackend.isDevBackend(url),
                           "\(url) is not the dev twin but was read as one")
        }
    }

    func testNothingConfiguredIsNotTheDevTwin() {
        for url in ["", "   ", "not a url at all"] {
            XCTAssertFalse(TileBackend.isDevBackend(url))
        }
    }

    // MARK: - What that decides

    func testTheChoiceOfBackendPicksTheRoots() {
        let dev = TileBackend(baseURLString: "https://dev.ataru.aryasasikumar.com/chat")
        XCTAssertTrue(dev.isDev)
        XCTAssertEqual(dev.apiRoot(.finance)?.absoluteString,
                       "https://dev.ataru.aryasasikumar.com/finance")

        let prod = TileBackend(baseURLString: "https://chat.ataru.aryasasikumar.com")
        XCTAssertFalse(prod.isDev)
        XCTAssertEqual(prod.apiRoot(.finance)?.absoluteString,
                       "https://ataru.aryasasikumar.com/finance")
        XCTAssertEqual(prod.apiRoot(.home)?.absoluteString,
                       "https://home.ataru.aryasasikumar.com")

        // Tiles with no JSON surface have no root on either backend, and must
        // not fall back to the other one's.
        XCTAssertNil(prod.apiRoot(.media))
        XCTAssertNil(dev.apiRoot(.media))
    }
}
