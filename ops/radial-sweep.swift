// radial-sweep.swift - the sweep's driver. NOT compiled on its own.
//
// `ops/radial-sweep.sh` slices `RadialArc` and `RadialFan` out of
// RadialTileMenu.swift, appends this file, and compiles the pair. So the
// geometry under test is always the geometry that ships, and this file only
// ever holds assertions.
//
// The claim being made, over every press on every screen ATARU runs on:
//
//   1. Aiming at a tile selects THAT tile. The bubble is drawn at
//      `origin + offset`; pointing a thumb at it must return its index.
//   2. A thumb resting anywhere inside a bubble selects it too, not just the
//      exact centre pixel.
//   3. The dead-zone ring, which is drawn at `origin`, selects nothing.
//   4. Whatever comes back is consistent with the drawing: the tile selected
//      is the angularly nearest one on its ring, measured from `origin`, and
//      its ring is one the reach from `origin` actually permits.
//   5. An unrevealed outer ring is never selectable.
//
// 1, 2 and 4 are the ones the nudged-fan bug broke: `index(at:)` took the
// angle from `origin` and the reach from `anchor`, and those are different
// points on every fan the solver had to nudge inward to seat.

// MARK: - Fixtures

/// Layer sizes as the view builds them: the size inside the safe area, inset
/// by `clearance`, with the navigation band and the composer band kept out.
private struct Layer {
    let name: String
    let size: CGSize
    /// Press grid spacing. Deliberately not a divisor of the dimensions, so
    /// the grid does not sit on round numbers.
    let step: Double
}

private let layers: [Layer] = [
    Layer(name: "6.3\" portrait",    size: CGSize(width: 402,  height: 818),  step: 22),
    Layer(name: "SE portrait",       size: CGSize(width: 375,  height: 647),  step: 23),
    Layer(name: "SE landscape",      size: CGSize(width: 667,  height: 355),  step: 23),
    Layer(name: "Pro Max portrait",  size: CGSize(width: 440,  height: 900),  step: 26),
    Layer(name: "Pro Max landscape", size: CGSize(width: 894,  height: 419),  step: 29),
    Layer(name: "iPad landscape",    size: CGSize(width: 1194, height: 790),  step: 37),
    Layer(name: "split narrow",      size: CGSize(width: 320,  height: 1150), step: 29),
]

private func field(_ size: CGSize) -> CGRect {
    CGRect(origin: .zero, size: size)
        .insetBy(dx: RadialFan.clearance, dy: RadialFan.clearance)
}

private func bands(_ size: CGSize) -> [CGRect] {
    [CGRect(x: 0, y: 0, width: size.width, height: 59),
     CGRect(x: 0, y: size.height * 0.85,
            width: size.width, height: size.height * 0.15)]
}

/// A 44pt bubble: a thumb anywhere in here is on the tile.
private let bubbleRadius: Double = 22

// MARK: - Tally

private final class Tally {
    var assertions = 0
    var presses = 0
    var nudgedPresses = 0
    var badPresses = 0
    var badNudgedPresses = 0
    var failures: [String: Int] = [:]
    var examples: [String] = []

    func check(_ ok: Bool, _ kind: String, _ message: @autoclosure () -> String) -> Bool {
        assertions += 1
        guard !ok else { return true }
        failures[kind, default: 0] += 1
        if examples.count < 12 { examples.append("[\(kind)] \(message())") }
        return false
    }

    var failed: Int { failures.values.reduce(0, +) }
}

// MARK: - Helpers, all in the frame the fan is DRAWN in

private func bubble(_ fan: RadialFan, _ i: Int) -> CGPoint {
    CGPoint(x: fan.origin.x + fan.offsets[i].width,
            y: fan.origin.y + fan.offsets[i].height)
}

private func direction(_ fan: RadialFan, to p: CGPoint) -> Double {
    atan2(p.y - fan.origin.y, p.x - fan.origin.x)
}

private func reach(_ fan: RadialFan, to p: CGPoint) -> Double {
    hypot(p.x - fan.origin.x, p.y - fan.origin.y)
}

/// Which ring an index lands on, and where that ring starts in `offsets`.
private func ringOf(_ fan: RadialFan, _ index: Int) -> (ring: Int, first: Int)? {
    var cursor = 0
    for (r, arc) in fan.rings.enumerated() {
        if index < cursor + arc.count { return (r, cursor) }
        cursor += arc.count
    }
    return nil
}

/// The outermost ring a reach may reach, by the same banding the menu uses -
/// re-derived here from `origin`, because the frame is the thing under test.
private func permittedRing(_ fan: RadialFan, reach: Double, visible: Int) -> Int {
    var ring = 0
    while ring + 1 < min(visible, fan.rings.count), reach >= fan.boundary(past: ring) {
        ring += 1
    }
    return ring
}

private func point(_ fan: RadialFan, angle: Double, reach r: Double) -> CGPoint {
    CGPoint(x: fan.origin.x + r * cos(angle), y: fan.origin.y + r * sin(angle))
}

// MARK: - One press

private func sweep(fan: RadialFan, at press: CGPoint, layer: String, into t: Tally) {
    guard !fan.rings.isEmpty else { return }
    let visible = fan.rings.count
    let where_ = "\(layer) press (\(Int(press.x)), \(Int(press.y)))"
    var clean = true

    // 1. Aiming straight at a tile selects that tile.
    for i in fan.offsets.indices {
        let p = bubble(fan, i)
        let got = fan.index(at: p, visibleRings: visible)
        clean = t.check(got == i, "aim-at-tile",
                        "\(where_): pointing at tile \(i) returned \(got.map(String.init) ?? "nil")") && clean
    }

    // 2. A thumb resting anywhere on the bubble selects it - the tile is a
    //    44pt target, not a pixel.
    let jitters: [CGSize] = [CGSize(width: 8, height: 0), CGSize(width: -8, height: 0),
                             CGSize(width: 0, height: 8), CGSize(width: 0, height: -8)]
    for i in fan.offsets.indices {
        let c = bubble(fan, i)
        for j in jitters {
            let p = CGPoint(x: c.x + j.width, y: c.y + j.height)
            guard reach(fan, to: p) > RadialFan.deadZone else { continue }
            let got = fan.index(at: p, visibleRings: visible)
            clean = t.check(got == i, "thumb-on-tile",
                            "\(where_): \(Int(hypot(j.width, j.height)))pt off tile \(i) returned \(got.map(String.init) ?? "nil")") && clean
        }
    }

    // 3. The dead-zone ring is drawn at `origin`, so it is the pivot that has
    //    to be dead. Inside it, nothing is chosen and releasing cancels.
    for k in 0..<24 {
        let a = -Double.pi + Double(k) * (2 * .pi / 24)
        for r in [RadialFan.deadZone * 0.3, RadialFan.deadZone * 0.95] {
            let p = point(fan, angle: a, reach: r)
            let got = fan.index(at: p, visibleRings: visible)
            clean = t.check(got == nil, "dead-zone",
                            "\(where_): \(Int(r))pt from the pivot selected \(got.map(String.init) ?? "nil")") && clean
        }
    }

    // 4. Everything that comes back agrees with the drawing.
    var reaches: [Double] = [RadialFan.deadZone + 2, fan.ringOne * 0.6, fan.ringOne,
                             fan.stageBoundary - 2, fan.stageBoundary + 2]
    for k in 0..<fan.rings.count { reaches.append(fan.radius(ofRing: k)) }
    reaches.append(fan.radius(ofRing: fan.rings.count - 1) + fan.ringGap * 0.6)
    for k in 0..<24 {
        let a = -Double.pi + Double(k) * (2 * .pi / 24)
        for r in reaches {
            let p = point(fan, angle: a, reach: r)
            guard let got = fan.index(at: p, visibleRings: visible) else { continue }
            guard let (ring, first) = ringOf(fan, got) else {
                clean = t.check(false, "index-range", "\(where_): returned \(got), off the end") && clean
                continue
            }
            // The tile chosen is the nearest one on its own ring, by the
            // angle the thumb is actually at as drawn.
            let mine = RadialFan.gap(direction(fan, to: bubble(fan, got)), a)
            for j in first..<(first + fan.rings[ring].count) {
                let theirs = RadialFan.gap(direction(fan, to: bubble(fan, j)), a)
                clean = t.check(theirs >= mine - 1e-9, "nearest-on-ring",
                                "\(where_): at \(Int(a * 180 / .pi))°/\(Int(r))pt chose \(got), but \(j) is nearer") && clean
            }
            // And its ring is one this reach permits. Falling INWARD is legal
            // - a partial outer ring must not swallow the gesture - so this
            // is an upper bound, not an equality.
            let allowed = permittedRing(fan, reach: r, visible: visible)
            clean = t.check(ring <= allowed, "ring-band",
                            "\(where_): reach \(Int(r))pt allows ring \(allowed) but chose tile \(got) on ring \(ring)") && clean
        }
    }

    // 5. Stage two cannot be aimed at before it is on screen.
    if fan.rings.count > 1 {
        let inner = fan.rings[0].count
        for i in inner..<fan.offsets.count {
            let got = fan.index(at: bubble(fan, i), visibleRings: 1)
            clean = t.check(got == nil || got! < inner, "unrevealed-ring",
                            "\(where_): an unrevealed tile \(i) was selected as \(got!)") && clean
        }
    }

    if !clean {
        t.badPresses += 1
        if fan.origin != fan.anchor { t.badNudgedPresses += 1 }
    }
}

// MARK: - Run

private let overall = Tally()
var rows: [(String, Int, Int, Int, Int)] = []

for layer in layers {
    let bounds = field(layer.size)
    let keepOut = bands(layer.size)
    let t = Tally()
    // Today's count, and one fewer: the screen already showing is never
    // offered, so both are live shapes.
    for count in [liveTileCount - 1, liveTileCount] {
        for x in stride(from: 0.0, through: layer.size.width, by: layer.step) {
            for y in stride(from: 0.0, through: layer.size.height, by: layer.step) {
                let press = CGPoint(x: x, y: y)
                let fan = RadialFan.solve(at: press, in: bounds, count: count,
                                          keepOut: keepOut)
                t.presses += 1
                if fan.origin != fan.anchor { t.nudgedPresses += 1 }
                sweep(fan: fan, at: press, layer: layer.name, into: t)
            }
        }
    }
    rows.append((layer.name, t.presses, t.nudgedPresses, t.badPresses, t.failed))
    overall.assertions += t.assertions
    overall.presses += t.presses
    overall.nudgedPresses += t.nudgedPresses
    overall.badPresses += t.badPresses
    overall.badNudgedPresses += t.badNudgedPresses
    for (k, v) in t.failures { overall.failures[k, default: 0] += v }
    for e in t.examples where overall.examples.count < 12 { overall.examples.append(e) }
}

func pad(_ s: String, _ n: Int) -> String {
    s.count >= n ? s : s + String(repeating: " ", count: n - s.count)
}
func rpad(_ s: String, _ n: Int) -> String {
    s.count >= n ? s : String(repeating: " ", count: n - s.count) + s
}

print("tiles: \(liveTileCount) (and \(liveTileCount - 1) with the current screen dropped)")
print("")
print(pad("layer", 18) + rpad("presses", 9) + rpad("nudged", 8)
      + rpad("bad", 8) + rpad("failed", 10))
for r in rows {
    print(pad(r.0, 18) + rpad("\(r.1)", 9) + rpad("\(r.2)", 8)
          + rpad("\(r.3)", 8) + rpad("\(r.4)", 10))
}
print(pad("TOTAL", 18) + rpad("\(overall.presses)", 9) + rpad("\(overall.nudgedPresses)", 8)
      + rpad("\(overall.badPresses)", 8) + rpad("\(overall.failed)", 10))
print("")
print("assertions: \(overall.assertions)")

if overall.failed == 0 {
    print("PASS - every press selects what it points at")
    exit(0)
}

print("misselecting presses: \(overall.badPresses)/\(overall.presses) "
      + "(\(overall.badNudgedPresses) of them on a nudged fan, "
      + "out of \(overall.nudgedPresses) nudged presses)")
print("")
for (k, v) in overall.failures.sorted(by: { $0.value > $1.value }) {
    print("  \(pad(k, 18)) \(v)")
}
print("")
for e in overall.examples { print("  " + e) }
print("FAIL")
exit(1)
