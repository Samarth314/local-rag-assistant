import XCTest
@testable import ATARU

/// The arithmetic behind "I can't see the field I'm typing into".
///
/// This bug has now been reported twice, and the second time was against a fix
/// that had been verified by building. That is the whole reason this file
/// exists: the failure is not a wiring mistake a compiler could catch, it is a
/// sum. The screen's fixed blocks added up to more than the height the keyboard
/// left behind, a SwiftUI frame does not clip, and the bottom of the column -
/// the composer - was drawn underneath the keyboard.
///
/// So the layout arithmetic was pulled out into `AskMetrics`, where it can be
/// swept across every plausible screen and keyboard instead of eyeballed on one
/// device. The claim is simple and absolute: **whatever the screen, whatever
/// the keyboard, the blocks fit in the space, and the composer is one of them.**
final class AskMetricsTests: XCTestCase {

    /// Content heights from an iPhone SE to an iPad, and keyboard overlaps from
    /// none to a Chinese keyboard with a candidate bar on a small phone.
    private let heights = stride(from: 320.0, through: 1100, by: 10.0)
    private let overlaps = stride(from: 0.0, through: 420, by: 10.0)

    func testTheBlocksAlwaysFitInTheHeightTheKeyboardLeaves() {
        for height in heights {
            for overlap in overlaps {
                let available = max(160, height - overlap)
                for focused in [true, false] {
                    for hasExchanges in [true, false] {
                        let m = AskMetrics.portrait(available: available,
                                                    focused: focused,
                                                    hasExchanges: hasExchanges)
                        XCTAssertLessThanOrEqual(
                            m.contentHeight + AskMetrics.chrome, available + 0.001,
                            """
                            \(m) overflows \(available)pt \
                            (screen \(height), keyboard \(overlap), \
                            focused \(focused), exchanges \(hasExchanges)) \
                            - this is the composer going under the keyboard
                            """)
                    }
                }
            }
        }
    }

    /// The composer is the point of the screen while the keyboard is up. It is
    /// never the block that yields.
    func testTheComposerIsNeverTheThingThatGivesWay() {
        for height in heights {
            for overlap in overlaps {
                let available = max(160, height - overlap)
                let m = AskMetrics.portrait(available: available, focused: true,
                                            hasExchanges: true)
                XCTAssertEqual(m.composer, AskMetrics.composerHeight,
                               "the composer was squeezed at \(available)pt")
            }
        }
    }

    /// The order things are given up in, on a phone-sized screen with a
    /// phone-sized keyboard: the transcript and the orb, never the composer,
    /// and the status label survives as long as anything does.
    func testTheOrbYieldsBeforeAnythingElseWorthKeeping() {
        // A 6.3" phone's content height, and a keyboard with a predictive bar.
        let available = 730.0 - 336.0
        let typing = AskMetrics.portrait(available: available, focused: true,
                                         hasExchanges: true)
        let resting = AskMetrics.portrait(available: 730, focused: false,
                                          hasExchanges: true)

        XCTAssertEqual(resting.orb, AskMetrics.fullOrb,
                       "with the keyboard down the orb should be full size")
        XCTAssertLessThan(typing.orb, resting.orb,
                          "the orb has to shrink to make room for the keyboard")
        XCTAssertGreaterThan(typing.transcript, 0,
                             "there is room for some conversation at this size")
        XCTAssertEqual(typing.composer, AskMetrics.composerHeight)
        XCTAssertGreaterThan(typing.status, 0, "the phase label always survives")
    }

    /// Small phone, keyboard up, nothing said yet: the orb goes rather than the
    /// field, and it is dropped outright rather than drawn as a smudge.
    func testAVeryShortScreenDropsTheOrbRatherThanTheField() {
        let m = AskMetrics.portrait(available: 200, focused: true,
                                    hasExchanges: false)
        XCTAssertEqual(m.composer, AskMetrics.composerHeight)
        XCTAssertFalse(m.showsOrb, "a 30pt orb is a smudge, not an object")
        XCTAssertEqual(m.transcript, 0)
    }

    /// Nothing is ever asked to draw itself at a negative size, which is the
    /// other way this kind of arithmetic fails.
    func testNoBlockIsEverNegative() {
        for available in stride(from: 0.0, through: 1100, by: 5.0) {
            for focused in [true, false] {
                let m = AskMetrics.portrait(available: available, focused: focused,
                                            hasExchanges: true)
                XCTAssertGreaterThanOrEqual(m.orb, 0)
                XCTAssertGreaterThanOrEqual(m.transcript, 0)
                XCTAssertGreaterThanOrEqual(m.status, 0)
                XCTAssertGreaterThanOrEqual(m.composer, 0)

                let l = AskMetrics.landscape(available: available, focused: focused)
                XCTAssertGreaterThanOrEqual(l.orb, 0)
                XCTAssertGreaterThanOrEqual(l.status, 0)
            }
        }
    }

    /// Landscape has far less height and is where this was worst. The orb and
    /// its label share one column, and that column fits too.
    func testTheLandscapeColumnFits() {
        for height in stride(from: 200.0, through: 500, by: 5.0) {
            for overlap in stride(from: 0.0, through: 260, by: 5.0) {
                let available = max(160, height - overlap)
                for focused in [true, false] {
                    let m = AskMetrics.landscape(available: available,
                                                 focused: focused)
                    XCTAssertLessThanOrEqual(m.orb + m.status, available,
                                             "the landscape column overflowed at \(available)pt")
                }
            }
        }
    }
}
