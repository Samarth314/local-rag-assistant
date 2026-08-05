import SwiftUI

/// Every surface ATARU has, as one routable set.
///
/// This is the single source of truth for destinations: the Tiles grid and
/// the radial launcher are two ways of launching the SAME set - the grid for
/// browsing, the dial for muscle memory. Every case opens a native screen;
/// nothing routes to a web page.
/// The declaration order IS the launcher's order, and the first
/// Declaration order is reach order: the earlier a tile is listed, the
/// sooner a thumb gets to it.
///
/// Stage one is chosen by how often a phone is the right device for the job:
/// the surfaces holding your own data, and the ones that change day to day.
/// Stage two is what is genuinely better on a bigger screen — a video server,
/// a music server, a handwriting canvas, and remote desktops.
///
/// Docker and Notify were removed outright. Portainer is a management console
/// for a machine, not something to poke at from a phone, and ntfy has nothing
/// to show: it pushes notifications, which arrive as notifications.
enum HomeTile: String, CaseIterable, Identifiable {
    // Stage one, in reach order.
    case assistant, plan, finance, health, journal, documents, home, workspaces
    // Stage two, revealed by pushing further out.
    case status, passwords, media, music, whiteboard, remote

    // NOTE: there is no `stageOneCount` any more, and no per-tile `stage`.
    // Which ring a tile lands on is decided by how much room the chosen
    // direction actually affords, so a fan that used to be hardcoded 8-then-6
    // now absorbs an added tile with no other change. Declaration order is
    // still REACH order - earlier tiles fill the inner ring first.

    var id: String { rawValue }

    var title: String {
        switch self {
        case .assistant:     return "Ask"
        case .plan:          return "Plan"
        case .finance:       return "Finance"
        case .health:        return "Health"
        case .home:          return "Home"
        case .status:        return "Status"
        case .journal:       return "Journal"
        case .workspaces:    return "Spaces"
        case .documents:     return "Docs"
        case .whiteboard:    return "Canvas"
        case .media:         return "Media"
        case .music:         return "Music"
        case .passwords:     return "Vault"
        case .remote:        return "Remote"
        }
    }

    var symbol: String {
        switch self {
        case .assistant:     return "waveform"
        case .plan:          return "checklist"
        case .finance:       return "dollarsign.circle"
        case .health:        return "heart.text.square"
        case .home:          return "lightbulb"
        case .status:        return "gauge.with.dots.needle.50percent"
        case .journal:       return "book.closed"
        case .workspaces:    return "square.stack.3d.up"
        case .documents:     return "tray.full"
        case .whiteboard:    return "scribble.variable"
        case .media:         return "play.rectangle"
        case .music:         return "music.note"
        case .passwords:     return "key"
        case .remote:        return "display"
        }
    }

    /// Subtitle shown on the grid tile.
    var kind: String {
        switch self {
        case .assistant:     return "Voice · chat"
        case .plan:          return "Top 3 · todos"
        case .finance:       return "Spending · net worth"
        case .health:        return "Labs · meds"
        case .home:          return "Devices · switches"
        case .status:        return "System dashboard"
        case .journal:       return "Write · reflect"
        case .workspaces:    return "Projects · notes"
        case .documents:     return "Browse · search"
        case .whiteboard:    return "AI canvas"
        case .media:         return "Jellyfin"
        case .music:         return "Navidrome"
        case .passwords:     return "Vaultwarden"
        case .remote:        return "Screens"
        }
    }

    /// The launcher manifest key this tile corresponds to, for health dots.
    var launcherKey: String {
        switch self {
        case .assistant:     return "chat"
        case .status:        return "dashboard"
        case .media:         return "jellyfin"
        case .music:         return "navidrome"
        case .passwords:     return "vaultwarden"
        case .whiteboard:    return "penecho"
        case .documents:     return "ingest"
        default:             return rawValue
        }
    }
}

// MARK: - Layout

/// One arc of the fan: where its tiles sit, and which one an angle points at.
///
/// An arc, never a closed ring. A full circle was tried and reverted: it reads
/// as a menu the thumb is standing inside rather than one it is aiming at, it
/// puts a third of the tiles under the hand that opened it, and it takes away
/// the "behind the fan" that makes sweeping backwards a cancel. What the arc
/// keeps from that work is the fitting — the sweep still narrows and turns to
/// whatever the press leaves room for, rather than assuming a whole screen.
struct RadialArc: Equatable {
    let radius: Double
    /// How much of the circle the tiles occupy.
    let sweep: Double
    /// The middle of the arc.
    let center: Double
    let count: Int

    var step: Double {
        guard count > 1 else { return 0 }
        return sweep / Double(count - 1)
    }

    /// Centre-to-centre distance between neighbours, which is what decides
    /// whether the tiles collide.
    var chord: Double {
        count > 1 ? 2 * radius * sin(step / 2) : .infinity
    }

    func angle(at index: Int) -> Double {
        guard count > 1 else { return center }
        return center - sweep / 2 + step * Double(index)
    }

    func offset(at index: Int) -> CGSize {
        let a = angle(at: index)
        return CGSize(width: radius * cos(a), height: radius * sin(a))
    }

    /// Which tile an angle points at, or nil for "behind the arc".
    func index(atAngle angle: Double) -> Int? {
        guard count > 0 else { return nil }
        guard count > 1 else { return 0 }
        // Measured from the arc's first tile and normalised into a full turn,
        // rather than into (-π, π]: an arc can be wider than a half circle,
        // and its far end would wrap to a negative number and read as behind.
        let relative = normalized(angle - (center - sweep / 2))
        // Half a step of tolerance past each end, and nothing beyond: sweeping
        // behind the fan should select nothing, not clamp to whichever end
        // happens to be closest.
        if relative <= sweep + step / 2 {
            return min(count - 1, Int((relative / step).rounded()))
        }
        return relative >= 2 * .pi - step / 2 ? 0 : nil
    }

    private func normalized(_ angle: Double) -> Double {
        let turn = 2 * Double.pi
        let remainder = angle.truncatingRemainder(dividingBy: turn)
        return remainder < 0 ? remainder + turn : remainder
    }
}

/// Where each tile goes for one particular press.
///
/// Solved once when the press lands and then held for its duration, so the fan
/// never rearranges under a moving thumb — and so the arithmetic runs once
/// rather than on every touch-moved event.
/// The whole fan: one shared centre, and rings filled to whatever that
/// direction affords.
///
/// THE BUG THIS REPLACES: the aim used to be an OUTPUT of the fit rather than
/// an input to it, and it was computed separately for each radius. So the two
/// arcs ended up pointing in different directions - measured 5-180° apart at
/// 85% of presses - and the fit was free to rotate the fan 45-68° to buy
/// itself sweep. That is why tiles landed level with and below the thumb, why
/// Vault came down on top of the composer and Status below it, and why pairs
/// overlapped by up to 17pt.
///
/// The inversion: choose ONE centre first - the direction nearest straight up
/// that can hold every tile - then fill each ring to capacity at that
/// direction. Ring count and per-ring counts fall out of the tile count, the
/// radii and the room available; nothing about "8 in the first arc and the
/// rest in the second" survives, so adding a tile no longer breaks the shape.
///
/// Sweep is never a scoring term. A ring earns exactly `(count-1)` steps of
/// width and no more, so the chord is exactly `minChord` on every ring of
/// every fan and an overlapping fan is not representable.
struct RadialFan: Equatable {
    /// Where the finger actually went down.
    let anchor: CGPoint
    /// Where the fan is centred. Separates from `anchor` only when no radius
    /// fits at the press itself and the whole cluster has to be nudged inward.
    /// Angles are measured from here, so a sweep still points at what it looks
    /// like it points at.
    let origin: CGPoint
    let offsets: [CGSize]
    /// Inner to outer. Every ring shares `center` - that is the fix.
    let rings: [RadialArc]
    let count: Int

    /// Travel below this is a wobble, not a choice - and releasing inside it
    /// is how you cancel.
    static let deadZone: Double = 34
    /// Radius of one bubble plus the breathing room it wants from an edge.
    static let clearance: Double = 30

    /// Closest two bubbles may sit centre to centre: a 44pt bubble plus enough
    /// gap to read as two things rather than a blob.
    private static let minChord: Double = 52
    private static let ringOne: Double = 120
    private static let ringGap: Double = 72
    private static let maxRings = 3
    /// Every tile must clear the thumb by this much. In the legality MASK, not
    /// the score - it constrains where a tile may be placed, not merely which
    /// placement is preferred.
    private static let liftMin: Double = 40
    /// A fuller inner ring may buy this much turn away from straight up, and
    /// no more. Turn is primary; width never outbids direction.
    private static let aimSlack: Double = .pi * 10 / 180
    private static let samples = 720
    private static let nudgeLadder: [Double] = [0, 30, 62, 100, 150]
    /// Tried in order, each relaxing one constraint. Only the last gives up
    /// any spacing, and only after lift has already been abandoned.
    private static let rungs: [(lift: Double?, chord: Double)] =
        [(40, 52), (16, 52), (nil, 52), (nil, 46)]

    // MARK: - The vocabulary the rest of the file reads the fan through

    var stageOne: RadialArc { rings.first ?? RadialArc(radius: Self.ringOne, sweep: 0, center: -.pi / 2, count: 0) }
    var stageTwo: RadialArc? { rings.count > 1 ? rings[1] : nil }
    var stageOneCount: Int { rings.first?.count ?? 0 }
    var centerAngle: Double { stageOne.center }
    var stageOneSweep: Double { stageOne.sweep }
    var stageTwoSweep: Double { stageTwo?.sweep ?? 0 }
    var stageOneRadius: Double { Self.ringOne }
    var stageTwoRadius: Double { Self.ringOne + Self.ringGap }

    func radius(ofRing i: Int) -> Double { Self.ringOne + Self.ringGap * Double(i) }
    /// Out past here brings the next ring in; back inside `hideRadius` takes
    /// it away. The gap between them is the hysteresis that stops a hovering
    /// thumb flickering the outer ring.
    func revealRadius(past i: Int) -> Double { radius(ofRing: i) + Self.ringGap * 0.20 }
    func hideRadius(past i: Int) -> Double {
        max(Self.deadZone + 8, radius(ofRing: i) + Self.ringGap * 0.10)
    }
    /// Where selection stops meaning ring i and starts meaning ring i+1.
    func boundary(past i: Int) -> Double {
        radius(ofRing: i) + max(28, Self.ringGap * 0.42)
    }
    var revealRadius: Double { revealRadius(past: 0) }
    var hideRadius: Double { hideRadius(past: 0) }
    var stageBoundary: Double { boundary(past: 0) }

    func visibleCount(rings n: Int) -> Int {
        rings.prefix(max(0, n)).reduce(0) { $0 + $1.count }
    }

    func distance(to point: CGPoint) -> Double {
        hypot(point.x - anchor.x, point.y - anchor.y)
    }

    /// Which tile a finger at `point` is pointing at, or nil for "nothing".
    ///
    /// Ring first, then angle - deliberately NOT nearest-bubble. Nearest-bubble
    /// was tried and reverted: it makes the outer ring steal selections from
    /// the inner one wherever the two are angularly close.
    func index(at point: CGPoint, visibleRings: Int) -> Int? {
        guard distance(to: point) > Self.deadZone, !rings.isEmpty else { return nil }
        let angle = atan2(point.y - origin.y, point.x - origin.x)
        let reach = distance(to: point)
        var ring = 0
        while ring + 1 < min(visibleRings, rings.count), reach >= boundary(past: ring) {
            ring += 1
        }
        // Fall inward if the ring the reach picked has nothing in this
        // direction - a partial outer ring must not swallow the gesture.
        while ring >= 0 {
            if let i = rings[ring].index(atAngle: angle) {
                return visibleCount(rings: ring) + i
            }
            ring -= 1
        }
        return nil
    }

    func index(at point: CGPoint, stageTwoVisible: Bool) -> Int? {
        index(at: point, visibleRings: stageTwoVisible ? rings.count : 1)
    }

    // MARK: - Solving

    static func solve(at point: CGPoint, in field: CGRect, count: Int,
                      keepOut: [CGRect] = []) -> RadialFan {
        let anchor = CGPoint(x: min(max(point.x, field.minX), field.maxX),
                            y: min(max(point.y, field.minY), field.maxY))
        guard count > 0 else {
            return RadialFan(anchor: anchor, origin: anchor, offsets: [],
                             rings: [], count: 0)
        }
        let target = CGPoint(x: field.midX, y: field.midY)
        let up = -Double.pi / 2

        for rung in rungs {
            for nudge in nudgeLadder {
                let origin = slide(anchor, toward: target, by: nudge)
                // Up is off the field entirely: mirror the fan downward rather
                // than letting it lean sideways to almost nothing.
                let preferred = (rung.lift == nil && anchor.y - ringOne < field.minY)
                    ? -up : up

                var rooms: [(radius: Double, mask: [Bool], left: [Int], right: [Int])] = []
                for k in 0..<maxRings {
                    let r = ringOne + ringGap * Double(k)
                    let mask = ringMask(origin: origin, radius: r, lift: rung.lift,
                                        field: field, keepOut: keepOut)
                    let (l, rr) = room(mask)
                    rooms.append((r, mask, l, rr))
                }

                // Fewest rings that still aim within aimSlack of the best
                // direction available: a ring is added to point the fan UP,
                // never to make it wider.
                var leastTurn: Double?
                for k in 1...maxRings {
                    guard let got = aim(Array(rooms.prefix(k)), count: count,
                                        chord: rung.chord, preferred: preferred)
                    else { continue }
                    let turn = gap(got.center, preferred)
                    if leastTurn == nil || turn < leastTurn! - 1e-9 { leastTurn = turn }
                }
                guard let least = leastTurn else { continue }
                for k in 1...maxRings {
                    guard let got = aim(Array(rooms.prefix(k)), count: count,
                                        chord: rung.chord, preferred: preferred),
                          gap(got.center, preferred) <= least + aimSlack + 1e-9
                    else { continue }
                    var built: [RadialArc] = []
                    for (i, n) in got.counts.enumerated() where n > 0 {
                        let r = rooms[i].radius
                        let step = 2 * asin(min(1, rung.chord / (2 * r)))
                        built.append(RadialArc(radius: r, sweep: step * Double(n - 1),
                                               center: got.center, count: n))
                    }
                    var offs: [CGSize] = []
                    for arc in built {
                        for i in 0..<arc.count { offs.append(arc.offset(at: i)) }
                    }
                    return RadialFan(anchor: anchor, origin: origin, offsets: offs,
                                     rings: built, count: count)
                }
            }
        }
        // Unreachable on any phone-sized field; a single ring beats nothing.
        let step = 2 * asin(min(1, minChord / (2 * ringOne)))
        let arc = RadialArc(radius: ringOne, sweep: step * Double(count - 1),
                            center: up, count: count)
        return RadialFan(anchor: anchor, origin: anchor,
                         offsets: (0..<count).map { arc.offset(at: $0) },
                         rings: [arc], count: count)
    }

    /// Legal directions for one ring: on the field, clear of every keep-out,
    /// and high enough above the thumb.
    private static func ringMask(origin: CGPoint, radius r: Double, lift: Double?,
                                 field: CGRect, keepOut: [CGRect]) -> [Bool] {
        let step = 2 * Double.pi / Double(samples)
        var mask = [Bool](repeating: false, count: samples)
        for i in 0..<samples {
            let a = -Double.pi + Double(i) * step
            // Per-RING lift, so an outer ring gets the room its height earns.
            if let lift, r * sin(a) > -lift { continue }
            let x = origin.x + r * cos(a), y = origin.y + r * sin(a)
            guard x >= field.minX - 1e-9, x <= field.maxX + 1e-9,
                  y >= field.minY - 1e-9, y <= field.maxY + 1e-9 else { continue }
            var blocked = false
            for k in keepOut where x >= k.minX - clearance && x <= k.maxX + clearance
                && y >= k.minY - clearance && y <= k.maxY + clearance {
                blocked = true
                break
            }
            mask[i] = !blocked
        }
        return mask
    }

    /// For every sample, how far the legal run extends each way. Anchored at a
    /// known gap so both scans are linear and wrap needs no special case.
    private static func room(_ mask: [Bool]) -> ([Int], [Int]) {
        let n = mask.count
        var left = [Int](repeating: 0, count: n), right = left
        guard let firstOut = mask.firstIndex(of: false) else {
            let big = n / 2
            return ([Int](repeating: big, count: n), [Int](repeating: big, count: n))
        }
        var run = 0
        for s in 0..<n {
            let i = (firstOut + s) % n
            run = mask[i] ? run + 1 : 0
            left[i] = max(0, run - 1)
        }
        run = 0
        for s in 0..<n {
            let i = ((firstOut - 1 - s) % n + n) % n
            run = mask[i] ? run + 1 : 0
            right[i] = max(0, run - 1)
        }
        return (left, right)
    }

    /// The shared centre for these rings, or nil if they cannot hold `count`.
    ///
    /// Aim is chosen FIRST: the direction nearest `preferred` that fits every
    /// tile. Then, among directions within `aimSlack` of it, the one putting
    /// the most tiles on the innermost ring. So a little turn may buy a fuller
    /// first ring, but a fuller first ring can never buy a lot of turn.
    private static func aim(_ rings: [(radius: Double, mask: [Bool], left: [Int], right: [Int])],
                            count: Int, chord: Double,
                            preferred: Double) -> (center: Double, counts: [Int])? {
        let step = 2 * Double.pi / Double(samples)
        var best: (turn: Double, center: Double, counts: [Int], first: Int)?
        var least = Double.infinity
        var feasible: [(turn: Double, center: Double, counts: [Int], first: Int)] = []
        for i in 0..<samples {
            let c = -Double.pi + Double(i) * step
            var counts: [Int] = []
            var remaining = count
            for ring in rings {
                var capacity = 0
                if ring.mask[i] {
                    let half = Double(min(ring.left[i], ring.right[i])) * step
                    let delta = 2 * asin(min(1, chord / (2 * ring.radius)))
                    capacity = Int(floor(2 * half / delta + 1e-9)) + 1
                }
                let take = min(capacity, remaining)
                counts.append(take)
                remaining -= take
            }
            guard remaining == 0 else { continue }
            let turn = gap(c, preferred)
            least = min(least, turn)
            feasible.append((turn, c, counts, counts.first ?? 0))
        }
        guard !feasible.isEmpty else { return nil }
        for f in feasible where f.turn <= least + aimSlack + 1e-9 {
            if best == nil || f.first > best!.first
                || (f.first == best!.first && f.turn < best!.turn) {
                best = f
            }
        }
        guard let b = best else { return nil }
        return (b.center, b.counts)
    }

    private static func slide(_ p: CGPoint, toward t: CGPoint, by d: Double) -> CGPoint {
        guard d > 0 else { return p }
        let dx = t.x - p.x, dy = t.y - p.y
        let len = hypot(dx, dy)
        guard len > 1e-3 else { return p }
        let travel = min(d, len)
        return CGPoint(x: p.x + dx / len * travel, y: p.y + dy / len * travel)
    }

    /// Shortest angular distance between two directions.
    static func gap(_ a: Double, _ b: Double) -> Double {
        abs(atan2(sin(a - b), cos(a - b)))
    }
}

// MARK: - View

/// Hold anywhere, sweep a thumb, release to choose.
///
/// ## Why it is invisible
///
/// The launcher used to be a circle parked at the bottom of every screen. It
/// worked, and it was still a permanent piece of chrome advertising a menu
/// that is only wanted for the half second someone reaches for it. So it is
/// gone: the app shows its content and nothing else until a thumb is held
/// down, and the fan opens *at the thumb* rather than somewhere it has to be
/// travelled to.
///
/// ## Why release commits
///
/// One press you never lift, instead of tap-then-tap. Nothing is committed
/// until release, so sliding back to the middle cancels — the gesture stays
/// reversible right up to the last moment, which is what makes it safe to
/// explore blind.
///
/// ## What is not here
///
/// No hit-testing, at all. Touches arrive from a recogniser on the window (see
/// `PressAnywhere`) and the bubbles are pure drawing, so this layer can sit
/// over the entire app permanently without intercepting a single tap. It also
/// means the fan is unreachable by VoiceOver and Switch Control, which cannot
/// press-and-sweep — the destinations menu in the navigation bar exists to be
/// that path, and must not be removed on the grounds that the dial does the
/// same job.
struct RadialPressMenu: View {
    /// Off during a call and while the keyboard is up.
    var isEnabled: Bool
    /// Places where holding already means something. See `PressAnywhere`.
    var exclusions: [CGRect]
    /// The screen already showing, left out of the fan. Offering the way to
    /// where you already are is offering a no-op, and it costs the ring a slot
    /// a real destination could have had.
    var current: HomeTile?
    let onSelect: (HomeTile) -> Void

    @State private var fan: RadialFan?
    @State private var highlighted: Int?
    /// Follows the thumb: out past `revealRadius` brings the second ring in,
    /// back inside `hideRadius` takes it away again, and the gap between the
    /// two is what stops it flickering on the threshold.
    ///
    /// This used to latch for the rest of the press, on the reasoning that
    /// tiles appearing and disappearing under a moving finger are unreadable.
    /// The hysteresis is the better answer to that: a sweep that went too far
    /// can now be taken back without lifting, which matters much more now
    /// that the reveal sits a fifth of the way out rather than most of a
    /// sweep away.
    @State private var stageTwoRevealed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var tiles: [HomeTile] {
        HomeTile.allCases.filter { $0 != current }
    }

    private let bubbleSize: CGFloat = 44

    var body: some View {
        GeometryReader { geo in
            // Global, because the recogniser reports window coordinates and
            // this layer is inset by the safe area — the fan should keep clear
            // of the notch and the home indicator, not merely of the screen.
            let frame = geo.frame(in: .global)

            ZStack {
                if let fan {
                    Color.black.opacity(0.55)
                        .ignoresSafeArea()

                    // Marks the pivot, and shows how far back is far enough to
                    // cancel.
                    Circle()
                        .strokeBorder(Theme.cyanSubdued.opacity(0.5), lineWidth: 1)
                        .frame(width: RadialFan.deadZone * 2,
                               height: RadialFan.deadZone * 2)
                        .position(fan.origin)

                    ForEach(Array(tiles.prefix(fan.offsets.count).enumerated()),
                            id: \.element.id) { index, tile in
                        // Stage two is not drawn until the thumb has asked for
                        // it. Ten tiles is about as many as can be taken in at
                        // a glance; fourteen is a wall.
                        if index < fan.stageOneCount || stageTwoRevealed {
                            let offset = fan.offsets[index]
                            TileBubble(tile: tile,
                                       isHighlighted: highlighted == index,
                                       size: bubbleSize)
                                .position(x: fan.origin.x + offset.width,
                                          y: fan.origin.y + offset.height)
                                // Out from under the thumb on the way in,
                                // scaled about the pivot rather than about
                                // itself so they read as thrown rather than
                                // faded into place.
                                //
                                // Out of focus on the way out. A plain
                                // opacity fade holds every edge crisp all the
                                // way to invisible, which on glass reads as
                                // the tiles being switched off; blurring as
                                // they go reads as them dissolving into the
                                // page, which is what is actually happening
                                // to them. Collapsing back to the pivot was
                                // the other option and is worse: it drags the
                                // eye back to where the thumb was at the
                                // exact moment the chosen screen arrives.
                                .transition(.asymmetric(
                                    insertion: .scale(scale: 0.2,
                                                      anchor: anchor(for: offset))
                                        .combined(with: .opacity),
                                    removal: .dissolve))
                        }
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .background(
                PressAnywhere(
                    isEnabled: isEnabled,
                    exclusions: exclusions,
                    onBegan: { open(at: $0, in: frame, size: geo.size) },
                    onMoved: { move(to: $0, in: frame) },
                    onEnded: commit
                )
            )
        }
        // Never takes a touch. Every one of them arrives from the window
        // recogniser instead, which is what lets this sit over the whole app.
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// The pivot, expressed in the bubble's own unit space. Values outside
    /// 0...1 are exactly the point: the pivot is nowhere near the bubble.
    private func anchor(for offset: CGSize) -> UnitPoint {
        UnitPoint(x: 0.5 - offset.width / bubbleSize,
                  y: 0.5 - offset.height / bubbleSize)
    }

    // MARK: - Gesture

    private func open(at point: CGPoint, in frame: CGRect, size: CGSize) {
        let local = CGPoint(x: point.x - frame.minX, y: point.y - frame.minY)
        let field = CGRect(origin: .zero, size: size)
            .insetBy(dx: RadialFan.clearance, dy: RadialFan.clearance)
        guard field.width > 0, field.height > 0 else { return }
        // Where a bubble may not land, whatever the press. The bottom band is
        // the composer: a "Vault" tile came down ON TOP of the text field and
        // "Status" below it, because nothing in the fit knew the composer was
        // there. Expressed as a fraction so it survives a different screen.
        let keepOut = [
            CGRect(x: 0, y: 0, width: size.width, height: 59),
            CGRect(x: 0, y: size.height * 0.85,
                   width: size.width, height: size.height * 0.15),
        ]

        highlighted = nil
        stageTwoRevealed = false
        withAnimation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.78)) {
            fan = RadialFan.solve(at: local, in: field, count: tiles.count,
                                  keepOut: keepOut)
        }
        Haptics.fire(.tap)
    }

    private func move(to point: CGPoint, in frame: CGRect) {
        guard let fan else { return }
        let local = CGPoint(x: point.x - frame.minX, y: point.y - frame.minY)

        // Reaching past the first ring brings out the rest, and coming back
        // inside puts them away — the stage follows the thumb rather than
        // latching, so a sweep that overshot can be taken back without
        // lifting. A firmer haptic than a selection tick either way, because
        // this changes what is on screen rather than moving within it, and by
        // this point the thumb is usually ahead of the eye.
        //
        // Settled rather than sprung. The reveal used to need most of a sweep
        // to reach and was a rare event; now it happens a fifth of the way
        // out and can happen more than once in a gesture, and a spring that
        // overshoots six bubbles into place that often reads as the fan
        // twitching rather than opening.
        if fan.count > fan.stageOneCount {
            let reach = fan.distance(to: local)
            let wanted = stageTwoRevealed ? reach > fan.hideRadius
                                          : reach > fan.revealRadius
            if wanted != stageTwoRevealed {
                withAnimation(reduceMotion ? nil : .spring(response: 0.34,
                                                           dampingFraction: 0.96)) {
                    stageTwoRevealed = wanted
                }
                Haptics.fire(.tap)
            }
        }

        let next = fan.index(at: local, stageTwoVisible: stageTwoRevealed)
        guard next != highlighted else { return }
        highlighted = next
        if next != nil { Haptics.fire(.selection) }
    }

    private func commit() {
        let chosen = highlighted.map { tiles[$0] }
        highlighted = nil
        stageTwoRevealed = false
        // Long enough to read as the fan dissolving into the page rather than
        // being cut, short enough that it is gone before the chosen screen
        // has finished arriving.
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.24)) {
            fan = nil
        }
        guard let chosen else { return }
        Haptics.fire(.success)
        onSelect(chosen)
    }
}

/// Softening, swelling and fading at once.
///
/// A plain opacity fade keeps every edge crisp the whole way to invisible,
/// which on glass reads as the tiles being switched off. Losing focus and
/// growing a little as they go reads as them dissolving into the page —
/// the same thing steam does leaving a mirror, and what is actually
/// happening to them.
private struct Dissolve: ViewModifier {
    /// 0 is the tile as drawn, 1 is gone.
    let amount: Double

    func body(content: Content) -> some View {
        content
            .blur(radius: amount * 9)
            .opacity(1 - amount)
            .scaleEffect(1 + amount * 0.12)
    }
}

extension AnyTransition {
    static var dissolve: AnyTransition {
        .modifier(active: Dissolve(amount: 1), identity: Dissolve(amount: 0))
    }
}

/// One option in the fan.
private struct TileBubble: View {
    let tile: HomeTile
    let isHighlighted: Bool
    let size: CGFloat

    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: tile.symbol)
                .font(.system(size: 14, weight: .light))
            Text(tile.title)
                .font(.system(size: 8, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .foregroundStyle(isHighlighted ? Theme.cyan : Theme.textSecondary)
        .frame(width: size, height: size)
        .background(Ataru.metal, in: Circle())
        .overlay {
            Circle().strokeBorder(
                isHighlighted ? Theme.cyan : Theme.border,
                lineWidth: isHighlighted ? 1.5 : 1
            )
        }
        .shadow(color: .black.opacity(0.3), radius: 10, y: 6)
        .scaleEffect(isHighlighted ? 1.18 : 1)
        .animation(.spring(response: 0.2, dampingFraction: 0.7), value: isHighlighted)
    }
}
