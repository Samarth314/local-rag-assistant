import XCTest
@testable import ATARU

/// Covers the parts of the call feature that are pure logic.
///
/// The CallKit round trip itself is not unit-tested: `CXProvider` talks to a
/// system daemon, and a test that stubs it would only assert that the stub was
/// called. What *is* worth pinning down is the state machine, because the app
/// has no call UI of its own — CallKit draws everything — so this enum is the
/// only thing tracking whether a call exists, and a wrong answer here means
/// audio running with no call or a call with no audio.
final class CallStateTests: XCTestCase {

    func testOnlyLiveStatesCountAsLive() {
        XCTAssertTrue(CallState.dialing.isLive)
        XCTAssertTrue(CallState.incoming.isLive)
        XCTAssertTrue(CallState.active(connectedAt: Date()).isLive)

        XCTAssertFalse(CallState.idle.isLive)
        XCTAssertFalse(CallState.ended(.hungUp).isLive)
        XCTAssertFalse(CallState.ended(.failed("no route")).isLive)
    }

    /// `isLive` gates whether a new call can start, so a state that lies here
    /// leaves the app permanently unable to place one.
    func testEveryEndedStateReleasesTheLine() {
        for reason in [CallEndReason.hungUp, .declined, .reset, .failed("x")] {
            XCTAssertFalse(CallState.ended(reason).isLive,
                           "\(reason) should free the line for the next call")
        }
    }

    func testStateLabelsAreDistinct() {
        let labels = [
            CallState.dialing.label,
            CallState.incoming.label,
            CallState.active(connectedAt: Date()).label,
            CallState.ended(.hungUp).label
        ]
        XCTAssertEqual(Set(labels).count, labels.count, "each state needs its own label")
    }

    /// `.active` carries a timestamp, so equality has to compare it — two calls
    /// connected at different moments are not the same call.
    func testActiveEqualityIncludesConnectionTime() {
        let now = Date()
        XCTAssertEqual(CallState.active(connectedAt: now), .active(connectedAt: now))
        XCTAssertNotEqual(CallState.active(connectedAt: now),
                          .active(connectedAt: now.addingTimeInterval(1)))
    }
}
