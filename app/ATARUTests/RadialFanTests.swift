import XCTest
@testable import ATARU

/// The launcher's geometry, which is the whole of its correctness.
///
/// Everything else about the radial menu is drawing and gesture plumbing that
/// only a device can exercise. This is not: the fan opens wherever a thumb
/// lands, so "does every tile stay on screen" has to hold for every point on
/// the screen, and that is exactly the kind of claim a test can make and a
/// simulator screenshot cannot.
///
/// The bug being guarded against is real and was shipped twice: a fan sized
/// for the middle of the screen, clipped at the edges.
final class RadialFanTests: XCTestCase {

    /// A 6.3" phone's safe area, inset the way the view insets it.
    private let field = CGRect(x: 0, y: 0, width: 402, height: 818)
        .insetBy(dx: RadialFan.clearance, dy: RadialFan.clearance)

    private func bubbles(_ fan: RadialFan) -> [CGPoint] {
        fan.offsets.map { CGPoint(x: fan.origin.x + $0.width,
                                  y: fan.origin.y + $0.height) }
    }

    /// Closed-interval containment, unlike `CGRect.contains`.
    ///
    /// `contains` is half-open — a point exactly on `maxX` or `maxY` is
    /// *outside* it. That is the correct answer for hit-testing and the wrong
    /// one here: a fan pushed flush against the edge lands its tiles exactly on
    /// the boundary by design, which is precisely the case worth asserting is
    /// fine. Using `contains` fails on the solver's best behaviour.
    private func isInside(_ point: CGPoint) -> Bool {
        point.x >= field.minX - 0.001 && point.x <= field.maxX + 0.001
            && point.y >= field.minY - 0.001 && point.y <= field.maxY + 0.001
    }

    // MARK: - Fitting

    func testEveryTileStaysOnScreenFromAnywhereIncludingTheCorners() {
        // A grid dense enough to catch an edge case in any single corner or
        // along any single edge, plus the exact corners themselves.
        for x in stride(from: 0.0, through: 402, by: 22) {
            for y in stride(from: 0.0, through: 818, by: 22) {
                let fan = RadialFan.solve(at: CGPoint(x: x, y: y),
                                          in: field, count: HomeTile.allCases.count)
                for (index, point) in bubbles(fan).enumerated() {
                    XCTAssertTrue(
                        isInside(point),
                        """
                        tile \(index) at \(point) escaped the field \(field) \
                        for a press at (\(x), \(y))
                        """
                    )
                }
            }
        }
    }

    func testAPressAtTheBottomFansUpward() {
        let fan = RadialFan.solve(at: CGPoint(x: 201, y: 800), in: field, count: HomeTile.allCases.count)
        // Every tile above the press, none below: the hand comes from the
        // bottom of the phone and covers anything fanned downward.
        for point in bubbles(fan) {
            XCTAssertLessThan(point.y, 800)
        }
    }

    func testAPressAtTheLeftEdgeFansRightRatherThanBeingShovedInward() {
        let fan = RadialFan.solve(at: CGPoint(x: 4, y: 409), in: field, count: HomeTile.allCases.count)

        // Turned toward the open side of the screen…
        XCTAssertGreaterThan(cos(fan.centerAngle), 0.5,
                             "the fan should point right, away from the left edge")
        // …rather than kept pointing up and dragged bodily into the middle,
        // which is what would put the tiles out of the thumb's reach.
        XCTAssertLessThan(abs(fan.origin.x - fan.anchor.x), 40)
    }

    func testAPressAtTheTopFansDownward() {
        let fan = RadialFan.solve(at: CGPoint(x: 201, y: 8), in: field, count: HomeTile.allCases.count)
        for point in bubbles(fan) {
            XCTAssertGreaterThan(point.y, 8)
        }
    }

    func testTilesDoNotOverlapEachOther() {
        let fan = RadialFan.solve(at: CGPoint(x: 201, y: 700), in: field, count: HomeTile.allCases.count)
        let points = bubbles(fan)
        // 44pt bubbles: anything closer than that centre-to-centre collides.
        for i in points.indices {
            for j in points.indices where j > i {
                let gap = hypot(points[i].x - points[j].x, points[i].y - points[j].y)
                XCTAssertGreaterThanOrEqual(gap, 44,
                                            "tiles \(i) and \(j) overlap (\(gap)pt apart)")
            }
        }
    }

    // MARK: - Selection

    func testTheDeadZoneSelectsNothing() {
        let fan = RadialFan.solve(at: CGPoint(x: 201, y: 700), in: field, count: HomeTile.allCases.count)
        XCTAssertNil(fan.index(at: fan.anchor, stageTwoVisible: true))
        XCTAssertNil(fan.index(at: CGPoint(x: fan.anchor.x + 20, y: fan.anchor.y), stageTwoVisible: true))
    }

    func testSweepingAtATileSelectsIt() {
        let fan = RadialFan.solve(at: CGPoint(x: 201, y: 700), in: field, count: HomeTile.allCases.count)

        // Aimed straight at each tile from the pivot, which is what a thumb
        // sweeping toward one approximates.
        for (index, offset) in fan.offsets.enumerated() {
            let point = CGPoint(x: fan.origin.x + offset.width,
                                y: fan.origin.y + offset.height)
            XCTAssertEqual(fan.index(at: point, stageTwoVisible: true), index,
                           "pointing at tile \(index) selected something else")
        }
    }

    // MARK: - Staging

    private func fanAtRest() -> RadialFan {
        RadialFan.solve(at: CGPoint(x: 201, y: 700), in: field,
                        count: HomeTile.allCases.count)
    }

    private func index(_ fan: RadialFan, at distance: Double,
                       stageTwoVisible: Bool) -> Int? {
        let up = -Double.pi / 2
        return fan.index(at: CGPoint(x: fan.origin.x + distance * cos(up),
                                     y: fan.origin.y + distance * sin(up)),
                         stageTwoVisible: stageTwoVisible)
    }

    func testAShortSweepStaysInStageOneAndALongOneReachesStageTwo() {
        let fan = fanAtRest()

        let short = index(fan, at: fan.stageOneRadius * 0.6, stageTwoVisible: true)
        let long = index(fan, at: fan.stageTwoRadius, stageTwoVisible: true)
        XCTAssertNotNil(short)
        XCTAssertNotNil(long)
        XCTAssertLessThan(short!, fan.stageOneCount,
                          "a short sweep should stay in stage one")
        XCTAssertGreaterThanOrEqual(long!, fan.stageOneCount,
                                    "a long sweep should reach stage two")
    }

    /// The one that matters: until the second arc is on screen, reaching past
    /// the first must not quietly select something invisible.
    func testStageTwoIsUnselectableUntilItIsRevealed() {
        let fan = fanAtRest()
        let far = index(fan, at: fan.stageTwoRadius, stageTwoVisible: false)

        XCTAssertNotNil(far, "reaching out should still select something")
        XCTAssertLessThan(far!, fan.stageOneCount,
                          "an unrevealed stage two must never be selectable")
    }

    func testTheRevealHappensBeforeStageTwoCanBeAimedAt() {
        let fan = fanAtRest()
        // Otherwise the second arc appears underneath a thumb already pointing
        // at one of its tiles, and whatever it lands on is a surprise.
        XCTAssertLessThan(fan.revealRadius, fan.stageBoundary)
        XCTAssertGreaterThan(fan.revealRadius, fan.stageOneRadius)
    }

    func testStageOneCarriesTheTilesWorthReachingForFirst() {
        let stageOne = Set(HomeTile.allCases.prefix(HomeTile.stageOneCount))
        for tile in [HomeTile.plan, .finance, .passwords, .health, .journal] {
            XCTAssertTrue(stageOne.contains(tile),
                          "\(tile.title) belongs in the first arc")
        }
        // Media and a handwriting canvas are better on a bigger screen.
        for tile in [HomeTile.media, .music, .whiteboard, .remote] {
            XCTAssertFalse(stageOne.contains(tile),
                           "\(tile.title) does not belong in the first arc")
        }
    }

    func testSweepingBehindTheFanSelectsNothing() {
        // Pressed mid-screen, so the fan points up and nothing has been
        // rotated: straight down is behind it.
        let fan = RadialFan.solve(at: CGPoint(x: 201, y: 409), in: field, count: HomeTile.allCases.count)
        XCTAssertEqual(fan.centerAngle, -Double.pi / 2, accuracy: 0.001)
        XCTAssertNil(fan.index(at: CGPoint(x: fan.origin.x, y: fan.origin.y + 120), stageTwoVisible: true),
                     "sweeping away from the fan should cancel, not clamp to an end tile")
    }
}
