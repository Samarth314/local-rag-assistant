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

    /// The same claim as above, from every press on the screen rather than
    /// from the one comfortable one in the middle.
    ///
    /// THE BUG THIS GUARDS: `index(at:)` took the angle from `origin` and the
    /// reach from `anchor`. Those are the same point only when the fan opens
    /// exactly where the thumb went down - and a quarter of the presses on
    /// this field are nudged inward to seat, more on a shorter one. On those,
    /// the direction and the ring were answered in different frames and the
    /// tile that came back was not the tile under the thumb. A standalone
    /// sweep (ops/radial-sweep.sh) put it at 2,595 of 7,922 presses across
    /// every layer, every one of them nudged and not one un-nudged.
    ///
    /// Testing this at a single press could never have caught it, because the
    /// press that was tested is not nudged.
    func testAimingAtATileSelectsItFromEveryPressIncludingNudgedFans() {
        var nudged = 0
        for x in stride(from: 0.0, through: 402, by: 22) {
            for y in stride(from: 0.0, through: 818, by: 22) {
                let fan = RadialFan.solve(at: CGPoint(x: x, y: y), in: field,
                                          count: HomeTile.allCases.count,
                                          keepOut: keepOut)
                if fan.origin != fan.anchor { nudged += 1 }
                for (index, point) in bubbles(fan).enumerated() {
                    XCTAssertEqual(
                        fan.index(at: point, stageTwoVisible: true), index,
                        """
                        pointing at tile \(index) selected something else for a \
                        press at (\(x), \(y)) \
                        (origin \(fan.origin), anchor \(fan.anchor))
                        """)
                    // And not merely the centre pixel: the bubble is a 44pt
                    // target, so a thumb resting anywhere on it counts.
                    for offset in [CGSize(width: 8, height: 0), CGSize(width: -8, height: 0),
                                   CGSize(width: 0, height: 8), CGSize(width: 0, height: -8)] {
                        let near = CGPoint(x: point.x + offset.width,
                                           y: point.y + offset.height)
                        guard hypot(near.x - fan.origin.x,
                                    near.y - fan.origin.y) > RadialFan.deadZone else { continue }
                        XCTAssertEqual(
                            fan.index(at: near, stageTwoVisible: true), index,
                            "resting 8pt off tile \(index) missed it at (\(x), \(y))")
                    }
                }
            }
        }
        // The case above is only covered while nudged fans actually occur. If
        // the solver ever stops nudging, this test has quietly stopped testing
        // the thing it exists for and should be re-aimed rather than deleted.
        XCTAssertGreaterThan(nudged, 0, "no press was nudged - this test proves nothing")
    }

    /// The dead zone is the circle that is DRAWN, which is at the origin.
    ///
    /// Same frame confusion, other half: measuring the cancel radius from the
    /// anchor means the ring someone can see is not the ring that cancels.
    func testTheDeadZoneIsTheCircleThatIsDrawnEvenWhenTheFanIsNudged() {
        // A left-edge press: the fan cannot be seated at the thumb, so it is
        // nudged 30pt inward.
        let fan = RadialFan.solve(at: CGPoint(x: 4, y: 409), in: field,
                                  count: HomeTile.allCases.count)
        XCTAssertNotEqual(fan.origin, fan.anchor, "this press is meant to nudge")

        for k in 0..<24 {
            let a = -Double.pi + Double(k) * (2 * .pi / 24)
            for r in [RadialFan.deadZone * 0.3, RadialFan.deadZone * 0.95] {
                let point = CGPoint(x: fan.origin.x + r * cos(a),
                                    y: fan.origin.y + r * sin(a))
                XCTAssertNil(fan.index(at: point, stageTwoVisible: true),
                             "\(Int(r))pt from the pivot selected a tile")
            }
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

    /// Coming back inside puts the second ring away, but not at the same
    /// radius that brought it out — a thumb hovering on one threshold would
    /// flicker six bubbles in and out.
    func testTheRingRetractsInsideTheRadiusThatRevealedIt() {
        for y in stride(from: 60.0, through: 780, by: 60) {
            let fan = RadialFan.solve(at: CGPoint(x: 201, y: y), in: field,
                                      count: HomeTile.allCases.count)
            XCTAssertLessThan(fan.hideRadius, fan.revealRadius,
                              "reveal and hide at one radius is a flicker (y=\(y))")
            XCTAssertGreaterThan(fan.revealRadius - fan.hideRadius, 5,
                                 "the gap is too narrow to absorb a wobble (y=\(y))")
            // The one that bites: retracting must not mean pulling back
            // through the first ring's own tiles. Easing off should be enough.
            XCTAssertGreaterThan(fan.hideRadius, fan.stageOneRadius,
                                 "changing your mind reaches inside stage one (y=\(y))")
            // And never inside the dead zone, or the ring could not be put
            // away without cancelling the whole gesture.
            XCTAssertGreaterThan(fan.hideRadius, RadialFan.deadZone)
        }
    }

    func testTheRevealHappensBeforeStageTwoCanBeAimedAt() {
        let fan = fanAtRest()
        // Otherwise the second arc appears underneath a thumb already pointing
        // at one of its tiles, and whatever it lands on is a surprise.
        XCTAssertLessThan(fan.revealRadius, fan.stageBoundary)
        XCTAssertGreaterThan(fan.revealRadius, fan.stageOneRadius)
    }

    /// The surviving half of the old `testStageOneCarriesTheTilesWorthReaching`
    /// -ForFirst, re-expressed against the ring model that replaced it.
    ///
    /// That test asserted a fixed split: `HomeTile.stageOneCount` was 8, and
    /// the first eight tiles were the first arc everywhere on the screen. Both
    /// the constant and the per-tile `stage` are gone, because how many tiles
    /// the inner ring holds now falls out of the room the press leaves - swept
    /// across the whole screen it ranges from 3 to 7, so no assertion about
    /// *which* tiles are on the inner ring can be true of every press.
    ///
    /// What survives is the intent, and it is a claim about the enum rather
    /// than about geometry: reach order is declaration order (the inner ring
    /// is filled first and in order - see the test below), so being early in
    /// `allCases` is what "within first reach" now means.
    func testDeclarationOrderPutsTheEverydayTilesWithinFirstReach() {
        let order = HomeTile.allCases
        func rank(_ tile: HomeTile) -> Int {
            order.firstIndex(of: tile) ?? Int.max
        }

        // The surfaces holding his own data, and the ones that change daily.
        let everyday: [HomeTile] = [.plan, .finance, .health, .journal]
        // A machine dashboard and a password manager are places you go on
        // purpose; media, music and a handwriting canvas want a bigger screen.
        let deliberate: [HomeTile] = [.status, .passwords, .media, .music,
                                      .whiteboard, .remote]

        for near in everyday {
            for far in deliberate {
                XCTAssertLessThan(
                    rank(near), rank(far),
                    "\(near.title) should be reached before \(far.title)")
            }
        }
        // Ask is the screen the app opens on, so it leads the order.
        XCTAssertEqual(order.first, .assistant)
    }

    func testSweepingBehindTheFanSelectsNothing() {
        // Pressed against the bottom edge, so the fan opens upward and
        // straight down is behind it.
        let fan = RadialFan.solve(at: CGPoint(x: 201, y: 812), in: field,
                                  count: HomeTile.allCases.count)
        XCTAssertEqual(fan.centerAngle, -Double.pi / 2, accuracy: 0.2)
        XCTAssertNil(fan.index(at: CGPoint(x: fan.origin.x, y: fan.origin.y + 120),
                               stageTwoVisible: true),
                     "sweeping away from the fan should cancel, not clamp to an end tile")
    }

    // MARK: - Shape

    /// An arc, never a closed ring — a full circle was tried and reverted.
    /// The bottom of the circle, where the hand is, stays empty from
    /// anywhere on the screen.
    func testTheFanIsAlwaysAnArcAndNeverWrapsTheThumb() {
        for x in stride(from: 0.0, through: 402, by: 40) {
            for y in stride(from: 0.0, through: 818, by: 40) {
                let fan = RadialFan.solve(at: CGPoint(x: x, y: y), in: field,
                                          count: HomeTile.allCases.count)
                XCTAssertLessThan(fan.stageOneSweep, 2 * .pi - 0.2,
                                  "the fan closed into a ring at (\(x), \(y))")
                XCTAssertLessThanOrEqual(fan.stageTwoSweep, 2 * .pi - 0.2)
            }
        }
    }

    func testAPressWithRoomAllRoundAimsStraightUp() {
        let fan = RadialFan.solve(at: CGPoint(x: 201, y: 380), in: field,
                                  count: HomeTile.allCases.count)
        // Direction, which IS chosen. Width is not asserted here: since
        // cef2a2a the aim is picked first — the nearest-to-straight-up
        // direction that holds every tile — and the rings then fill to
        // whatever that direction affords, so sweep is an OUTPUT. The arc is
        // deliberately not maximised, and pinning it to a number is pinning
        // the solver's arithmetic rather than its behaviour.
        XCTAssertEqual(fan.centerAngle, -Double.pi / 2, accuracy: 0.05)
        // Every tile above the press, none below.
        for point in bubbles(fan) {
            XCTAssertLessThan(point.y, 380 + 1)
        }
    }

    /// Room buys width. Which direction it buys it in is the aim's business,
    /// but an open press must not fan NARROWER than a cornered one.
    ///
    /// The relative claim is the one worth making. Both of the assertions this
    /// replaced were absolute angles, and both were wrong about a solver that
    /// treats sweep as a result.
    func testRoomAllRoundFansWiderThanAnEdgePress() {
        let open = RadialFan.solve(at: CGPoint(x: 201, y: 380), in: field,
                                   count: HomeTile.allCases.count)
        let edge = RadialFan.solve(at: CGPoint(x: 4, y: 409), in: field,
                                   count: HomeTile.allCases.count)
        XCTAssertGreaterThan(open.stageOneSweep, edge.stageOneSweep,
                             "an open press should not fan narrower than a cornered one")
    }

    /// The floor the old tests were really reaching for: not "the arc is wide"
    /// but "the arc is not so narrow that its own tiles collide".
    ///
    /// Derived from the solver's rung ladder rather than a hardcoded angle, so
    /// retuning the ladder retunes this rather than breaking it.
    func testAnArcIsAlwaysWideEnoughToSeatItsOwnTiles() {
        for x in stride(from: 0.0, through: 402, by: 26) {
            for y in stride(from: 0.0, through: 818, by: 26) {
                let fan = RadialFan.solve(at: CGPoint(x: x, y: y), in: field,
                                          count: HomeTile.allCases.count)
                for (index, ring) in fan.rings.enumerated() where ring.count > 1 {
                    XCTAssertGreaterThanOrEqual(
                        ring.chord, RadialFan.minimumChord - 0.001,
                        """
                        ring \(index) packed its \(ring.count) tiles \
                        \(ring.chord)pt apart at (\(x), \(y)), under the \
                        \(RadialFan.minimumChord)pt floor
                        """)
                }
            }
        }
    }

    /// The arc slides inside the room it has; it does not sit in the middle
    /// of it.
    ///
    /// A press low and centre leaves the outer ring ~285° to play with,
    /// because the only thing off screen at that radius is a wedge past the
    /// right edge. Centring the 104° arc on that run's midpoint aims it
    /// straight left, which is how six tiles ended up stacked down the
    /// left-hand edge with the inner ring still pointing up.
    func testAnArcWithRoomToSpareStillPointsUpward() {
        let fan = RadialFan.solve(at: CGPoint(x: 223, y: 576), in: field,
                                  count: HomeTile.allCases.count)
        XCTAssertEqual(fan.centerAngle, -Double.pi / 2, accuracy: 0.3,
                       "the first arc drifted off straight up")
        let outer = try? XCTUnwrap(fan.stageTwo)
        XCTAssertEqual(outer?.center ?? 0, -Double.pi / 2, accuracy: 0.3,
                       "the second arc is not over the top with the first")
        // Which is to say: both arcs stay above the press, not beside it.
        for point in bubbles(fan) {
            XCTAssertLessThan(point.y, 576, "a tile fanned level with or below the thumb")
        }
    }

    func testAnEdgePressTurnsTowardTheOpenSideAndStillSeatsEveryTile() {
        let fan = RadialFan.solve(at: CGPoint(x: 4, y: 409), in: field,
                                  count: HomeTile.allCases.count)
        XCTAssertGreaterThan(cos(fan.centerAngle), 0.5,
                             "it should turn toward the open side")
        // The old assertion here demanded half a turn of sweep, on the theory
        // that less meant the solver had "given up on the arc". It has not
        // given up: a cornered press legitimately fans narrow, and every tile
        // is still placed and still on screen — which is what
        // testEveryTileStaysOnScreenFromAnywhereIncludingTheCorners and the
        // spacing floor above actually check.
        XCTAssertEqual(fan.offsets.count, HomeTile.allCases.count,
                       "an edge press must still place every tile")
        for point in bubbles(fan) {
            XCTAssertTrue(isInside(point), "a tile escaped at an edge press")
        }
    }

    // MARK: - The current screen

    func testDroppingTheCurrentScreenStillFitsAndStaysOnScreen() {
        // Ask is showing, so it is not offered: thirteen tiles. How they split
        // across the rings is the solver's business and no longer passed in -
        // `solve` has no `stageOneCount:` parameter, because there is no fixed
        // first-arc size to hand it.
        let count = HomeTile.allCases.count - 1

        for x in stride(from: 0.0, through: 402, by: 33) {
            for y in stride(from: 0.0, through: 818, by: 33) {
                let fan = RadialFan.solve(at: CGPoint(x: x, y: y), in: field,
                                          count: count)
                XCTAssertEqual(fan.offsets.count, count)
                XCTAssertEqual(fan.rings.reduce(0) { $0 + $1.count }, count,
                               "the rings stopped accounting for every tile")
                for point in bubbles(fan) {
                    XCTAssertTrue(isInside(point),
                                  "a tile escaped for a press at (\(x), \(y))")
                }
            }
        }
    }

    // MARK: - Reach

    /// The gap between the rings has to hold the boundary clear of both, or
    /// the tile under the thumb is not the tile that gets picked.
    func testRestingOnAnInnerTileCannotSelectAnOuterOne() {
        let bubbleRadius: Double = 22
        for y in stride(from: 60.0, through: 780, by: 60) {
            let fan = RadialFan.solve(at: CGPoint(x: 201, y: y), in: field,
                                      count: HomeTile.allCases.count)
            XCTAssertGreaterThan(fan.stageBoundary, fan.stageOneRadius + bubbleRadius,
                                 "aiming at an inner tile crosses into stage two at y=\(y)")
            XCTAssertLessThan(fan.stageBoundary, fan.stageTwoRadius - bubbleRadius,
                              "stage two cannot be chosen without reaching it at y=\(y)")
        }
    }

    func testTheSecondRingTriggersWellBeforeItsTilesAreReached() {
        let fan = fanAtRest()
        // The boundary is what a thumb has to cross, and it sits nearer than
        // halfway to the bubbles it selects — reaching them is not the price
        // of choosing them.
        XCTAssertLessThan(fan.stageBoundary,
                          (fan.stageOneRadius + fan.stageTwoRadius) / 2,
                          "stage two should trigger before the halfway point")
        XCTAssertGreaterThan(fan.stageBoundary, fan.stageOneRadius)
    }

    // MARK: - The ring model
    //
    // What replaced the hardcoded 8-then-6 split: one aim chosen first, then
    // rings filled to whatever that direction affords. These are the
    // invariants that survive a changed tile count, which the old fixed-split
    // assertions could not.
    //
    // The bands are the ones `RadialPressMenu.open(at:in:size:)` actually
    // hands to `solve` - the navigation bar at the top and the composer across
    // the bottom 15%. Passing them here is the difference between "the fan
    // fits the screen" and "the fan fits the screen someone is using".

    private let screen = CGSize(width: 402, height: 818)

    private var composerBand: CGRect {
        CGRect(x: 0, y: screen.height * 0.85,
               width: screen.width, height: screen.height * 0.15)
    }

    private var keepOut: [CGRect] {
        [CGRect(x: 0, y: 0, width: screen.width, height: 59), composerBand]
    }

    /// Inner to outer, in order: the offsets are grouped ring by ring, so the
    /// first `rings[0].count` tiles are the ones a thumb reaches first.
    ///
    /// This is what makes reach order and declaration order the same thing,
    /// and it is the invariant the tile priority test above leans on.
    func testTheInnerRingIsFilledFirstAndInDeclarationOrder() {
        for x in stride(from: 0.0, through: 402, by: 22) {
            for y in stride(from: 0.0, through: 818, by: 22) {
                let fan = RadialFan.solve(at: CGPoint(x: x, y: y), in: field,
                                          count: HomeTile.allCases.count,
                                          keepOut: keepOut)
                var cursor = 0
                for (i, ring) in fan.rings.enumerated() {
                    XCTAssertGreaterThan(ring.count, 0,
                                         "an empty ring was built at (\(x), \(y))")
                    if i > 0 {
                        XCTAssertGreaterThan(
                            ring.radius, fan.rings[i - 1].radius,
                            "ring \(i) is not outside ring \(i - 1) at (\(x), \(y))")
                    }
                    for k in 0..<ring.count {
                        let offset = fan.offsets[cursor + k]
                        XCTAssertEqual(
                            hypot(offset.width, offset.height), ring.radius,
                            accuracy: 0.001,
                            "tile \(cursor + k) is not on ring \(i) at (\(x), \(y))")
                    }
                    cursor += ring.count
                }
                XCTAssertEqual(cursor, fan.offsets.count)
            }
        }
    }

    /// Coaxial, which is the entire point of the rewrite: the aim is an INPUT
    /// to the fit now, chosen once and shared. It used to be an output
    /// computed per radius, which is how the two arcs ended up pointing in
    /// different directions at 85% of presses.
    func testEveryRingSharesTheOneChosenAim() {
        for x in stride(from: 0.0, through: 402, by: 22) {
            for y in stride(from: 0.0, through: 818, by: 22) {
                let fan = RadialFan.solve(at: CGPoint(x: x, y: y), in: field,
                                          count: HomeTile.allCases.count,
                                          keepOut: keepOut)
                guard let aim = fan.rings.first?.center else { continue }
                for (i, ring) in fan.rings.enumerated() {
                    XCTAssertEqual(ring.center, aim, accuracy: 1e-9,
                                   "ring \(i) drifted off the shared aim at (\(x), \(y))")
                }
                XCTAssertEqual(fan.centerAngle, aim, accuracy: 1e-9)
            }
        }
    }

    /// A constant 72pt between rings, and every ring on that ladder. The gap
    /// is what holds the selection boundary clear of both rings' bubbles, so a
    /// ring landing between rungs would put the boundary inside a tile.
    func testTheRingsSitOnALadderOfConstantGaps() {
        for i in 0..<3 {
            let fan = fanAtRest()
            XCTAssertEqual(fan.radius(ofRing: i + 1) - fan.radius(ofRing: i), 72,
                           accuracy: 1e-9, "the ring gap is not constant")
        }
        for y in stride(from: 0.0, through: 818, by: 22) {
            let fan = RadialFan.solve(at: CGPoint(x: 201, y: y), in: field,
                                      count: HomeTile.allCases.count,
                                      keepOut: keepOut)
            for (i, ring) in fan.rings.enumerated() {
                let onLadder = (0..<4).contains {
                    abs(fan.radius(ofRing: $0) - ring.radius) < 1e-9
                }
                XCTAssertTrue(onLadder,
                              "ring \(i) at r=\(ring.radius) is off the ladder (y=\(y))")
            }
        }
    }

    /// 52pt centre to centre: a 44pt bubble plus enough gap to read as two
    /// things rather than a blob. The solver has a give-up rung that would
    /// spend this down to 46, and a phone-sized field never reaches it - swept
    /// across the screen the closest two tiles come is exactly 52.
    func testNoTwoTilesComeCloserThanFiftyTwoPoints() {
        for x in stride(from: 0.0, through: 402, by: 22) {
            for y in stride(from: 0.0, through: 818, by: 22) {
                let fan = RadialFan.solve(at: CGPoint(x: x, y: y), in: field,
                                          count: HomeTile.allCases.count,
                                          keepOut: keepOut)
                let points = bubbles(fan)
                for i in points.indices {
                    for j in points.indices where j > i {
                        let gap = hypot(points[i].x - points[j].x,
                                        points[i].y - points[j].y)
                        XCTAssertGreaterThanOrEqual(
                            gap, 52 - 0.001,
                            "tiles \(i) and \(j) are \(gap)pt apart at (\(x), \(y))")
                    }
                }
            }
        }
    }

    /// On the field and off the composer, from anywhere.
    ///
    /// This is the shipped-twice bug: a fan sized for the middle of the
    /// screen, clipped at the edges — and its sequel, a "Vault" tile coming
    /// down on top of the text field because nothing in the fit knew the
    /// composer was there.
    func testEveryTileStaysOnTheFieldAndClearOfTheComposerBand() {
        for x in stride(from: 0.0, through: 402, by: 22) {
            for y in stride(from: 0.0, through: 818, by: 22) {
                let fan = RadialFan.solve(at: CGPoint(x: x, y: y), in: field,
                                          count: HomeTile.allCases.count,
                                          keepOut: keepOut)
                for (i, point) in bubbles(fan).enumerated() {
                    XCTAssertTrue(isInside(point),
                                  "tile \(i) at \(point) escaped for (\(x), \(y))")
                    guard point.x >= composerBand.minX,
                          point.x <= composerBand.maxX else { continue }
                    XCTAssertLessThan(
                        point.y, composerBand.minY,
                        "tile \(i) landed in the composer band at (\(x), \(y))")
                    // And not merely a hair above it: the mask blocks every
                    // direction within `clearance` of a keep-out, so a tile
                    // grazing the band means the mask stopped being applied.
                    XCTAssertGreaterThan(
                        composerBand.minY - point.y, 24,
                        "tile \(i) grazed the composer band at (\(x), \(y))")
                }
            }
        }
    }

    // MARK: - Landscape, and small screens
    //
    // THE SWEEP'S BLIND SPOT, and it shipped a broken launcher. Every test
    // above uses ONE field: a 6.3" phone in portrait. The solver's ring ladder
    // is fixed at 120pt with 72pt gaps, and whether a ring can be seated at
    // all depends on the field - so on any SHORTER field the outer rings have
    // no legal band at the shared aim, the total capacity falls below the tile
    // count, every rung fails, and the last-resort fallback used to place all
    // sixteen tiles on one ring while consulting neither the field nor the
    // count. That is the landscape screenshot with Vault, Media and Music off
    // the right-hand edge - and it was equally true of an iPhone SE in
    // portrait, which this suite also never modelled.
    //
    // These are the fields as the view actually builds them: the layer size
    // inside the safe area, inset by `clearance`, with the navigation band and
    // the composer band as keep-outs.

    private func field(_ size: CGSize) -> CGRect {
        CGRect(origin: .zero, size: size)
            .insetBy(dx: RadialFan.clearance, dy: RadialFan.clearance)
    }

    private func bands(_ size: CGSize) -> [CGRect] {
        [CGRect(x: 0, y: 0, width: size.width, height: 59),
         CGRect(x: 0, y: size.height * 0.85,
                width: size.width, height: size.height * 0.15)]
    }

    /// Layer sizes, inside the safe area: the smallest phone, the largest, and
    /// a tablet, each on both of its sides.
    private let layers: [(name: String, size: CGSize)] = [
        ("SE portrait", CGSize(width: 375, height: 647)),
        ("SE landscape", CGSize(width: 667, height: 355)),
        ("Pro Max portrait", CGSize(width: 440, height: 900)),
        ("Pro Max landscape", CGSize(width: 894, height: 419)),
        ("iPad landscape", CGSize(width: 1194, height: 790)),
        ("split narrow", CGSize(width: 320, height: 1150)),
    ]

    func testEveryTileStaysOnEveryScreenInEveryOrientation() {
        for (name, size) in layers {
            let bounds = field(size)
            let keepOut = bands(size)
            for count in [HomeTile.allCases.count - 1, HomeTile.allCases.count] {
                for x in stride(from: 0.0, through: size.width, by: 37) {
                    for y in stride(from: 0.0, through: size.height, by: 37) {
                        let fan = RadialFan.solve(at: CGPoint(x: x, y: y),
                                                  in: bounds, count: count,
                                                  keepOut: keepOut)
                        XCTAssertEqual(fan.offsets.count, count,
                                       "\(name) dropped a tile at (\(x), \(y))")
                        let points = fan.offsets.map {
                            CGPoint(x: fan.origin.x + $0.width,
                                    y: fan.origin.y + $0.height)
                        }
                        for (i, p) in points.enumerated() {
                            XCTAssertTrue(
                                p.x >= bounds.minX - 0.001 && p.x <= bounds.maxX + 0.001
                                    && p.y >= bounds.minY - 0.001 && p.y <= bounds.maxY + 0.001,
                                "\(name): tile \(i) at \(p) escaped \(bounds) for a press at (\(x), \(y))")
                        }
                        // Bubbles are 44pt whatever the ladder does, so this
                        // has to hold across RINGS as well as within one -
                        // the chord rule only ever compares neighbours on the
                        // same arc, which is how a shrunken ring gap put two
                        // tiles 36pt apart.
                        for i in points.indices {
                            for j in points.indices where j > i {
                                let gap = hypot(points[i].x - points[j].x,
                                                points[i].y - points[j].y)
                                XCTAssertGreaterThanOrEqual(
                                    gap, RadialFan.minimumChord - 0.001,
                                    "\(name): tiles \(i) and \(j) are \(gap)pt apart at (\(x), \(y))")
                            }
                        }
                    }
                }
            }
        }
    }

    /// A fan that closes into a ring has no "behind" to sweep back to, and
    /// sweeping back is how the gesture is cancelled. True on a short field
    /// too, which is where the old fallback produced a sweep wider than a full
    /// circle.
    func testTheFanStaysAnArcOnEveryScreen() {
        for (name, size) in layers {
            let bounds = field(size)
            let keepOut = bands(size)
            for x in stride(from: 0.0, through: size.width, by: 53) {
                for y in stride(from: 0.0, through: size.height, by: 53) {
                    let fan = RadialFan.solve(at: CGPoint(x: x, y: y), in: bounds,
                                              count: HomeTile.allCases.count,
                                              keepOut: keepOut)
                    for (i, ring) in fan.rings.enumerated() {
                        XCTAssertLessThan(ring.sweep, 2 * .pi - 0.2,
                                          "\(name): ring \(i) closed at (\(x), \(y))")
                    }
                }
            }
        }
    }

    /// The portrait phone this was all tuned on is placed exactly as it was
    /// before the ladder learned to shrink: the first three rungs are the old
    /// ones, and a 6.3" field has always been seated by the first.
    func testTheShrinkingLadderNeverFiresWhereTheOldOneWorked() {
        for x in stride(from: 0.0, through: 402, by: 22) {
            for y in stride(from: 0.0, through: 818, by: 22) {
                let fan = RadialFan.solve(at: CGPoint(x: x, y: y), in: field,
                                          count: HomeTile.allCases.count,
                                          keepOut: keepOut)
                XCTAssertEqual(fan.ringOne, RadialFan.baseRingOne, accuracy: 1e-9,
                               "the ladder shrank on a portrait phone at (\(x), \(y))")
                XCTAssertEqual(fan.ringGap, RadialFan.baseRingGap, accuracy: 1e-9)
            }
        }
    }

    /// The property that makes adding a tile safe: nothing anywhere declares
    /// how the tiles divide up, so the division cannot fall out of step with
    /// the count. Parameterised over today's count, one fewer (the current
    /// screen is never offered) and two more.
    func testRingCountsAreDerivedFromTheTileCountAndSumToIt() {
        let live = HomeTile.allCases.count
        for count in [live - 1, live, live + 1, live + 2] {
            for x in stride(from: 0.0, through: 402, by: 40) {
                for y in stride(from: 0.0, through: 818, by: 40) {
                    let fan = RadialFan.solve(at: CGPoint(x: x, y: y), in: field,
                                              count: count, keepOut: keepOut)
                    XCTAssertEqual(fan.rings.reduce(0) { $0 + $1.count }, count,
                                   "\(count) tiles did not divide up at (\(x), \(y))")
                    XCTAssertEqual(fan.offsets.count, count,
                                   "\(count) tiles produced \(fan.offsets.count) offsets")
                    XCTAssertEqual(fan.count, count)
                    XCTAssertLessThanOrEqual(fan.rings.count, 3,
                                             "a fourth ring appeared at (\(x), \(y))")
                    for point in bubbles(fan) {
                        XCTAssertTrue(isInside(point),
                                      "\(count) tiles overflowed at (\(x), \(y))")
                    }
                }
            }
        }
    }
}
