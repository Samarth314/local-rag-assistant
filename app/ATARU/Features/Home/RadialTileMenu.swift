import SwiftUI

/// Every surface ATARU has, as one routable set.
///
/// This is the single source of truth for destinations: the Tiles grid and
/// the radial launcher are two ways of launching the SAME set - the grid for
/// browsing, the dial for muscle memory. Every case opens a native screen;
/// nothing routes to a web page.
/// The declaration order IS the launcher's order, and the first
/// `stageOneCount` of them are the ones a thumb reaches without looking.
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

    /// How many tiles the first arc carries. The rest wait on the second.
    ///
    /// Eight, not ten: Status and Vault came out. Both are things you go and
    /// look at deliberately — a machine dashboard and a password manager — not
    /// things a thumb should trip over on the way to the day's work.
    static let stageOneCount = 8

    var id: String { rawValue }

    enum Stage { case one, two }

    /// Which arc this tile rides on. Declaration order is the launcher's
    /// order, so the split is positional — one list, not two to keep in sync.
    var stage: Stage {
        let index = Self.allCases.firstIndex(of: self) ?? 0
        return index < Self.stageOneCount ? .one : .two
    }

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

/// One ring of the fan: where its tiles sit, and which one an angle points at.
///
/// A ring closes into a full circle whenever the press has room for one, and
/// otherwise carries as much of a circle as fits — the two cases differ only
/// in how the tiles are spaced (a closed ring's last tile neighbours its
/// first, so it divides by the count rather than the gaps between them) and
/// in whether there is a "behind the arc" at all.
struct RadialArc: Equatable {
    let radius: Double
    /// How much of the circle the tiles occupy. `2π` is a closed ring.
    let sweep: Double
    /// The middle of the arc — or, for a closed ring, where its first tile sits.
    let center: Double
    let count: Int

    var isClosed: Bool { sweep >= 2 * .pi - 0.0001 }

    var step: Double {
        guard count > 1 else { return 0 }
        return isClosed ? sweep / Double(count) : sweep / Double(count - 1)
    }

    /// Centre-to-centre distance between neighbours, which is what decides
    /// whether the tiles collide.
    var chord: Double {
        count > 1 ? 2 * radius * sin(step / 2) : .infinity
    }

    func angle(at index: Int) -> Double {
        guard count > 1 else { return center }
        return isClosed
            ? center + step * Double(index)
            : center - sweep / 2 + step * Double(index)
    }

    func offset(at index: Int) -> CGSize {
        let a = angle(at: index)
        return CGSize(width: radius * cos(a), height: radius * sin(a))
    }

    /// Which tile an angle points at, or nil for "behind the arc".
    func index(atAngle angle: Double) -> Int? {
        guard count > 0 else { return nil }
        guard count > 1 else { return 0 }
        if isClosed {
            // A ring has no behind: every direction points at something.
            let turns = (wrapped(angle - center) / step).rounded()
            return ((Int(turns) % count) + count) % count
        }
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

    private func wrapped(_ angle: Double) -> Double {
        atan2(sin(angle), cos(angle))
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
struct RadialFan: Equatable {
    /// Where the finger actually went down.
    let anchor: CGPoint
    /// Where the fan is centred. Usually the same as `anchor`; it separates
    /// only when no radius can fit the tiles at the press itself and the whole
    /// cluster has to be nudged inward. Angles are measured from here, so a
    /// sweep still points at what it looks like it points at.
    let origin: CGPoint
    let offsets: [CGSize]

    let stageOne: RadialArc
    /// Absent only in a field too small to hold an outer ring at all.
    let stageTwo: RadialArc?
    let count: Int

    // The vocabulary the rest of the app reads the fan through.
    var stageOneRadius: Double { stageOne.radius }
    var stageTwoRadius: Double { stageTwo?.radius ?? stageOne.radius }
    var stageOneCount: Int { stageOne.count }
    var centerAngle: Double { stageOne.center }
    var stageOneSweep: Double { stageOne.sweep }
    var stageTwoSweep: Double { stageTwo?.sweep ?? 0 }
    /// Whether the first ring closed the loop.
    var isClosed: Bool { stageOne.isClosed }

    /// Travel below this is a wobble, not a choice — and releasing inside it
    /// is how you cancel.
    static let deadZone: Double = 34

    /// Radius of one bubble plus the breathing room it wants from the edge.
    static let clearance: Double = 30

    /// Closest two bubbles may sit centre to centre. A 44pt bubble plus enough
    /// of a gap to read as two things rather than a blob.
    private static let minChord: Double = 52

    /// Ring sizes tried, nearest the thumb first.
    ///
    /// A ring only closes when the whole circle clears the edges, so a small
    /// one is often the difference between a circle and an arc — but 88 was
    /// too small to be comfortable: eight 44pt bubbles on that circumference
    /// leave 25pt of gap, which reads as cramped and makes the tiles look
    /// like they snap into place rather than fan out. 104 is the tightest
    /// ring that still breathes.
    private static let radiusLadder: [Double] = [104, 120, 136, 152, 168]

    /// Ratios of the outer ring to the inner, tried in order.
    ///
    /// The gap has to hold three things without them running together: the
    /// outer half of an inner bubble, the boundary where aiming switches
    /// rings, and the inner half of an outer bubble. At 1.8 that is about
    /// 70pt for three things needing ~22, ~6 and ~22 — tight, and anything
    /// closer makes resting on an inner tile select an outer one.
    private static let outerRatios: [Double] = [1.80, 1.95, 2.10]

    /// How far the fan may be dragged off the thumb when nothing fits at the
    /// press itself — a corner press being the case that needs it.
    private static let nudgeLadder: [Double] = [0, 30, 62, 100, 150]

    /// How far out the second stage appears, as a fraction of the gap between
    /// the rings. Early on purpose: the reveal should happen while the thumb
    /// is still travelling, so stage two is on screen well before it can be
    /// aimed at, rather than materialising under the finger.
    private static let revealFraction: Double = 0.20

    /// Where aiming stops meaning stage one and starts meaning stage two.
    /// Nearer than halfway, so reaching the outer ring is a short push rather
    /// than a stretch to where its bubbles are actually drawn.
    private static let boundaryFraction: Double = 0.42

    /// How far past the inner ring the boundary must sit regardless: half a
    /// bubble, plus enough that resting on an inner tile — which means
    /// touching anywhere within its 22pt radius — cannot cross it.
    private static let boundaryClearance: Double = 28

    /// Push past this and the rest of the tiles appear.
    var revealRadius: Double {
        stageOneRadius + (stageTwoRadius - stageOneRadius) * Self.revealFraction
    }

    /// The boundary between "aiming at stage one" and "aiming at stage two".
    var stageBoundary: Double {
        max(stageOneRadius + Self.boundaryClearance,
            stageOneRadius + (stageTwoRadius - stageOneRadius) * Self.boundaryFraction)
    }

    /// Straight up. The hand comes from the bottom of the phone, so a partial
    /// arc opens away from the palm — and a closed ring starts its first tile
    /// there, where the eye already is.
    private static let preferredAngle = -Double.pi / 2

    /// Fits the fan around `point`, keeping every bubble inside `field`.
    ///
    /// `field` is the region a bubble *centre* may occupy — already inset by
    /// `clearance` — so containment here means visibly clear of the edge, not
    /// merely touching it.
    ///
    /// The shape is chosen, not fixed: a press with room in every direction
    /// gets a closed ring, and one against an edge gets as much of a circle as
    /// that edge leaves. Three knobs, in order of preference — ring size
    /// first, since a slightly wider ring often turns a three-quarter arc into
    /// a whole circle; then how much of the circle survives; and only when no
    /// size fits the tiles at all, sliding the whole cluster inward, which is
    /// a last resort because it moves the tiles away from the thumb.
    static func solve(at point: CGPoint, in field: CGRect, count: Int,
                      stageOneCount requestedStageOne: Int = HomeTile.stageOneCount) -> RadialFan {
        let anchor = CGPoint(x: min(max(point.x, field.minX), field.maxX),
                             y: min(max(point.y, field.minY), field.maxY))
        let oneCount = max(0, min(requestedStageOne, count))
        let twoCount = count - oneCount
        let target = CGPoint(x: field.midX, y: field.midY)

        // The least-bad shape seen anywhere, in case the tiles cannot be made
        // to fit at any size from any origin.
        var fallback: (score: Double, origin: CGPoint, arc: RadialArc)?

        for nudge in nudgeLadder {
            let origin = slide(anchor, toward: target, by: nudge)
            var bestHere: (score: Double, arc: RadialArc)?

            for radius in radiusLadder {
                let (sweep, center) = widestArc(origin: origin, radius: radius, in: field)
                guard sweep > 0 else { continue }
                let closed = sweep >= 2 * .pi - 0.0001
                let arc = RadialArc(radius: radius, sweep: sweep,
                                    center: closed ? preferredAngle : center,
                                    count: oneCount)
                // A ring is the ideal; failing that, the most circle this spot
                // can hold. Both dominate the mild preference for a short
                // reach, which only breaks ties between equal shapes.
                let score = (closed ? 0 : 260) - sweep * 26 + radius * 0.35

                if arc.chord >= minChord {
                    if bestHere == nil || score < bestHere!.score {
                        bestHere = (score, arc)
                    }
                } else if fallback == nil || score + nudge < fallback!.score {
                    fallback = (score + nudge, origin, arc)
                }
            }

            // Fitting where the thumb actually landed beats any shape bought
            // by dragging the fan away from it — which is why this returns on
            // the first nudge level that works rather than scoring them
            // against each other. Sliding is what happens when a corner press
            // leaves no room for the tiles at all, not a way to buy a circle.
            if let bestHere {
                return assemble(anchor: anchor, origin: origin, inner: bestHere.arc,
                                stageTwoCount: twoCount, in: field)
            }
        }

        // A field too small to hold the tiles anywhere. Draw the roomiest
        // thing we saw rather than nothing at all.
        guard let fallback else {
            return RadialFan(anchor: anchor, origin: anchor, offsets: [],
                             stageOne: RadialArc(radius: 0, sweep: 0,
                                                 center: preferredAngle, count: 0),
                             stageTwo: nil, count: 0)
        }
        return assemble(anchor: anchor, origin: fallback.origin, inner: fallback.arc,
                        stageTwoCount: twoCount, in: field)
    }

    private static func assemble(anchor: CGPoint, origin: CGPoint, inner: RadialArc,
                                 stageTwoCount: Int, in field: CGRect) -> RadialFan {
        let outer = outerArc(around: origin, inner: inner,
                             count: stageTwoCount, in: field)
        var offsets = (0..<inner.count).map { inner.offset(at: $0) }
        if let outer {
            offsets += (0..<outer.count).map { outer.offset(at: $0) }
        }
        return RadialFan(anchor: anchor, origin: origin, offsets: offsets,
                         stageOne: inner, stageTwo: outer, count: offsets.count)
    }

    /// The outer ring, sized so its bubbles clear the inner ring's.
    private static func outerArc(around origin: CGPoint, inner: RadialArc,
                                 count: Int, in field: CGRect) -> RadialArc? {
        guard count > 0 else { return nil }
        var fallback: RadialArc?
        for ratio in outerRatios {
            let radius = inner.radius * ratio
            let (sweep, center) = widestArc(origin: origin, radius: radius, in: field)
            guard sweep > 0 else { continue }
            let closed = sweep >= 2 * .pi - 0.0001
            let arc = RadialArc(radius: radius, sweep: sweep,
                                center: closed ? preferredAngle : center,
                                count: count)
            if arc.chord >= minChord { return arc }
            if fallback == nil || arc.chord > fallback!.chord { fallback = arc }
        }
        return fallback
    }

    /// The widest run of angles at `radius` whose bubble centres stay inside
    /// `field`, as (sweep, centre); `2π` when the whole circle fits.
    ///
    /// Sampled rather than solved. The closed form is four inverse-trig cases
    /// each with their own degenerate ones, this runs once per press, and at a
    /// degree of resolution the error where a bubble lands is a hundredth of a
    /// point.
    private static func widestArc(origin: CGPoint, radius: Double,
                                  in field: CGRect) -> (sweep: Double, center: Double) {
        let samples = 360
        let stepAngle = 2 * Double.pi / Double(samples)
        let inside = (0..<samples).map { index -> Bool in
            let angle = Double(index) * stepAngle
            let x = Double(origin.x) + radius * cos(angle)
            let y = Double(origin.y) + radius * sin(angle)
            return x >= field.minX && x <= field.maxX
                && y >= field.minY && y <= field.maxY
        }
        guard let firstOutside = inside.firstIndex(of: false) else {
            return (2 * .pi, preferredAngle)
        }

        // Walking from a known gap makes the longest run a plain linear scan
        // rather than a wrap-around one.
        var best = (start: 0, length: 0)
        var run = (start: 0, length: 0)
        for step in 0..<samples {
            let index = (firstOutside + step) % samples
            if inside[index] {
                if run.length == 0 { run.start = index }
                run.length += 1
                if run.length > best.length { best = run }
            } else {
                run.length = 0
            }
        }
        guard best.length > 1 else { return (0, preferredAngle) }

        let sweep = Double(best.length - 1) * stepAngle
        // Wrapped into (-π, π]. The trigonometry does not care, but a centre
        // angle that reads as 4.71 where every other angle in the file reads
        // as -1.57 is a trap for the next person to compare two of them.
        let middle = Double(best.start) * stepAngle + sweep / 2
        return (sweep, atan2(sin(middle), cos(middle)))
    }

    private static func slide(_ point: CGPoint, toward target: CGPoint,
                              by distance: Double) -> CGPoint {
        guard distance > 0 else { return point }
        let dx = Double(target.x - point.x)
        let dy = Double(target.y - point.y)
        let length = hypot(dx, dy)
        guard length > 0.001 else { return point }
        let travel = min(distance, length)
        return CGPoint(x: point.x + dx / length * travel,
                       y: point.y + dy / length * travel)
    }

    /// How far the thumb is from the pivot.
    func distance(to point: CGPoint) -> Double {
        hypot(Double(point.x - origin.x), Double(point.y - origin.y))
    }

    /// Which tile the thumb is currently pointing at, by index.
    ///
    /// Matched by stage-then-angle rather than by nearest bubble. Nearest-bubble
    /// makes the second stage almost unreachable: it sits far out, and a thumb
    /// pivoting from the base of the hand rarely travels that far. Here the
    /// distance only has to cross the boundary between the rings, so both
    /// stages are inside comfortable reach.
    ///
    /// `stageTwoVisible` is passed in rather than inferred: until the thumb has
    /// pushed far enough to reveal the second ring, aiming past the first one
    /// must not silently select a tile that is not on screen yet.
    func index(at point: CGPoint, stageTwoVisible: Bool) -> Int? {
        guard hypot(point.x - anchor.x, point.y - anchor.y) > Self.deadZone else { return nil }
        let angle = atan2(Double(point.y - origin.y), Double(point.x - origin.x))

        if stageTwoVisible, let stageTwo, distance(to: point) >= stageBoundary,
           let index = stageTwo.index(atAngle: angle) {
            return stageOne.count + index
        }
        // Also the fallback when the outer ring has nothing in that direction:
        // pushing further out should never cost the highlight the thumb had.
        return stageOne.index(atAngle: angle)
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
    /// Latches once the thumb has pushed past the first arc, and stays latched
    /// for the rest of the press. Sweeping back inside must not take the second
    /// stage away again: tiles flickering in and out under a moving finger is
    /// unreadable, and the whole point of the staging is that stage one is
    /// uncluttered *until you ask for more*, not that it toggles.
    @State private var stageTwoRevealed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var tiles: [HomeTile] {
        HomeTile.allCases.filter { $0 != current }
    }

    /// Recomputed rather than taken from `HomeTile.stageOneCount`, because
    /// dropping the current screen may have come out of either ring.
    private var stageOneCount: Int {
        tiles.filter { $0.stage == .one }.count
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

        highlighted = nil
        stageTwoRevealed = false
        withAnimation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.78)) {
            fan = RadialFan.solve(at: local, in: field, count: tiles.count,
                                  stageOneCount: stageOneCount)
        }
        Haptics.fire(.tap)
    }

    private func move(to point: CGPoint, in frame: CGRect) {
        guard let fan else { return }
        let local = CGPoint(x: point.x - frame.minX, y: point.y - frame.minY)

        // Reaching past the first arc brings out the rest. A firmer haptic than
        // a selection tick, because this is a change to what is on screen
        // rather than a move within it — and the thumb is usually ahead of the
        // eye by this point.
        if !stageTwoRevealed,
           fan.count > fan.stageOneCount,
           fan.distance(to: local) > fan.revealRadius {
            // Settled rather than sprung. The reveal used to need most of a
            // sweep to reach and was a rare event; now it happens a fifth of
            // the way out, on nearly every gesture, and a spring that
            // overshoots six bubbles into place that often reads as the fan
            // twitching rather than opening.
            withAnimation(reduceMotion ? nil : .spring(response: 0.34,
                                                       dampingFraction: 0.96)) {
                stageTwoRevealed = true
            }
            Haptics.fire(.tap)
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
