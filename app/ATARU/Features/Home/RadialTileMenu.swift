import SwiftUI

/// Every surface ATARU has, as one routable set.
///
/// This is the single source of truth for destinations: the Tiles grid and
/// the radial launcher are two ways of launching the SAME set - the grid for
/// browsing, the dial for muscle memory. Every case opens a native screen;
/// nothing routes to a web page.
enum HomeTile: String, CaseIterable, Identifiable {
    // Inner ring: the core daily surfaces.
    case assistant, plan, finance, health, home, status, journal, workspaces
    // Outer ring: the rest of the homelab.
    case documents, whiteboard, media, music, passwords, containers,
         notifications, remote

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
        case .containers:    return "Docker"
        case .notifications: return "Notify"
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
        case .containers:    return "shippingbox"
        case .notifications: return "bell.badge"
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
        case .containers:    return "Portainer"
        case .notifications: return "ntfy"
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
        case .containers:    return "portainer"
        case .notifications: return "ntfy"
        case .whiteboard:    return "penecho"
        case .documents:     return "ingest"
        default:             return rawValue
        }
    }
}

// MARK: - Layout

/// Where each tile goes for one particular press.
///
/// Solved once when the press lands and then held for its duration, so the fan
/// never rearranges under a moving thumb — and so the arithmetic runs once
/// rather than on every touch-moved event.
struct RadialFan: Equatable {
    /// Where the finger actually went down.
    let anchor: CGPoint
    /// Where the fan is centred. Usually the same as `anchor`; it separates
    /// only when no orientation fits and the whole cluster has to be nudged
    /// inward. Angles are measured from here, so a sweep still points at what
    /// it looks like it points at.
    let origin: CGPoint
    let offsets: [CGSize]

    let innerRadius: Double
    let outerRadius: Double
    let innerCount: Int
    let count: Int
    let centerAngle: Double
    let innerSweep: Double
    let outerSweep: Double

    /// Travel below this is a wobble, not a choice — and releasing inside it
    /// is how you cancel.
    static let deadZone: Double = 34

    /// Radius of one bubble plus the breathing room it wants from the edge.
    static let clearance: Double = 30

    // Two rings, because sixteen tiles on one arc either overlap or need a
    // radius no thumb can reach. The outer arc is the narrower of the two:
    // its ends are the points that run into the left and right edges first,
    // so pulling them in is what buys the whole fan its room.
    private static let innerSweepDefault = Double.pi * 176 / 180
    private static let outerSweepDefault = Double.pi * 140 / 180

    /// Straight up. The hand comes from the bottom of the phone, so anywhere
    /// else is a direction the palm covers.
    private static let preferredAngle = -Double.pi / 2

    /// Fits the fan around `point`, keeping every bubble inside `field`.
    ///
    /// `field` is the region a bubble *centre* may occupy — already inset by
    /// `clearance` — so containment here means visibly clear of the edge, not
    /// merely touching it.
    ///
    /// Two knobs, in order of preference. First the orientation: the fan turns
    /// away from whichever edges are close, which is why pressing low fans up
    /// and pressing at the left edge fans right. Then, only if no orientation
    /// fits, the whole cluster slides inward — a last resort, because sliding
    /// moves the tiles away from the thumb that has to reach them.
    static func solve(at point: CGPoint, in field: CGRect, count: Int) -> RadialFan {
        let anchor = CGPoint(x: min(max(point.x, field.minX), field.maxX),
                             y: min(max(point.y, field.minY), field.maxY))
        let innerCount = min(8, count)
        let outerCount = count - innerCount
        let innerSweep = innerSweepDefault
        let outerSweep = outerSweepDefault

        // Scaled to the screen rather than fixed, so a narrow phone gets a
        // smaller fan instead of one that has to be shoved sideways to fit.
        // The half-width of the outer arc is `radius * sin(sweep / 2)`, so
        // inverting that gives the largest radius the field can hold.
        let widthLimit = (field.width / 2) / sin(outerSweep / 2)
        let outerRadius = max(96, min(172, widthLimit, field.height * 0.45))
        let innerRadius = outerRadius * 0.665

        func offsets(_ centerAngle: Double) -> [CGSize] {
            (0..<count).map { index in
                let isInner = index < innerCount
                let indexInRing = isInner ? index : index - innerCount
                let ringCount = isInner ? innerCount : outerCount
                let radius = isInner ? innerRadius : outerRadius
                let sweep = isInner ? innerSweep : outerSweep
                let step = ringCount > 1 ? sweep / Double(ringCount - 1) : 0
                let angle = centerAngle - sweep / 2 + step * Double(indexInRing)
                return CGSize(width: radius * cos(angle), height: radius * sin(angle))
            }
        }

        /// How far this orientation would have to be dragged back on screen,
        /// and by how much it cannot be saved at all.
        func fit(_ offsets: [CGSize]) -> (shift: CGSize, overflow: Double) {
            var box = CGRect(x: anchor.x, y: anchor.y, width: 0, height: 0)
            for offset in offsets {
                box = box.union(CGRect(x: anchor.x + offset.width,
                                       y: anchor.y + offset.height,
                                       width: 0, height: 0))
            }
            var shift = CGSize.zero
            var overflow: Double = 0

            if box.width <= field.width {
                shift.width = max(0, field.minX - box.minX) - max(0, box.maxX - field.maxX)
            } else {
                shift.width = field.midX - box.midX
                overflow += box.width - field.width
            }
            if box.height <= field.height {
                shift.height = max(0, field.minY - box.minY) - max(0, box.maxY - field.maxY)
            } else {
                shift.height = field.midY - box.midY
                overflow += box.height - field.height
            }
            return (shift, overflow)
        }

        // Start from the direction with the most room, then try every 15°
        // around from there. Turning is cheap (40pt of penalty per radian,
        // so a right angle costs about 63pt); not fitting is not (×4).
        var best: (angle: Double, offsets: [CGSize], shift: CGSize, score: Double)?
        for step in 0...24 {
            // 0, +15, -15, +30, -30 … so ties resolve toward the ideal.
            let turn = Double((step + 1) / 2) * (step % 2 == 0 ? 1 : -1) * .pi / 12
            let angle = preferredAngle + turn
            let candidate = offsets(angle)
            let (shift, overflow) = fit(candidate)
            let score = hypot(shift.width, shift.height)
                + overflow * 4
                + abs(turn) * 40
            if best == nil || score < best!.score {
                best = (angle, candidate, shift, score)
            }
            // Every remaining candidate turns at least this far, so none of
            // them can beat what we already have.
            if let best, abs(turn) * 40 >= best.score { break }
        }

        let chosen = best!
        return RadialFan(
            anchor: anchor,
            origin: CGPoint(x: anchor.x + chosen.shift.width,
                            y: anchor.y + chosen.shift.height),
            offsets: chosen.offsets,
            innerRadius: innerRadius,
            outerRadius: outerRadius,
            innerCount: innerCount,
            count: count,
            centerAngle: chosen.angle,
            innerSweep: innerSweep,
            outerSweep: outerSweep
        )
    }

    /// Which tile the thumb is currently pointing at, by index.
    ///
    /// Matched by ring-then-angle rather than by nearest bubble. Nearest-bubble
    /// makes the outer ring almost unreachable: it sits 172pt out, and a thumb
    /// pivoting from the base of the hand rarely travels that far. Here the
    /// distance only has to cross the halfway line to mean "outer", so both
    /// rings are inside comfortable reach.
    func index(at point: CGPoint) -> Int? {
        guard hypot(point.x - anchor.x, point.y - anchor.y) > Self.deadZone else { return nil }

        let dx = Double(point.x - origin.x)
        let dy = Double(point.y - origin.y)
        let distance = hypot(dx, dy)
        let outerCount = count - innerCount
        let isInner = distance < (innerRadius + outerRadius) / 2 || outerCount == 0

        let ringCount = isInner ? innerCount : outerCount
        let sweep = isInner ? innerSweep : outerSweep
        guard ringCount > 1 else { return ringCount == 1 ? (isInner ? 0 : innerCount) : nil }
        let step = sweep / Double(ringCount - 1)

        // Angle relative to the arc's first tile, wrapped into (-π, π] so the
        // comparison works whichever way the fan is turned.
        let raw = atan2(dy, dx) - (centerAngle - sweep / 2)
        let relative = atan2(sin(raw), cos(raw))
        // Half a step of tolerance past each end, and nothing beyond: sweeping
        // behind the fan should select nothing, not clamp to whichever end
        // happens to be closest.
        guard relative >= -step / 2, relative <= sweep + step / 2 else { return nil }

        let indexInRing = min(ringCount - 1, max(0, Int((relative / step).rounded())))
        return isInner ? indexInRing : innerCount + indexInRing
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
    let onSelect: (HomeTile) -> Void

    @State private var fan: RadialFan?
    @State private var highlighted: Int?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let tiles = HomeTile.allCases
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
                        let offset = fan.offsets[index]
                        TileBubble(tile: tile,
                                   isHighlighted: highlighted == index,
                                   size: bubbleSize)
                            .position(x: fan.origin.x + offset.width,
                                      y: fan.origin.y + offset.height)
                            // Scaled about the pivot rather than about itself,
                            // so the tiles read as thrown out from under the
                            // thumb instead of simply fading in where they land.
                            .transition(
                                .scale(scale: 0.2, anchor: anchor(for: offset))
                                    .combined(with: .opacity))
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
        withAnimation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.78)) {
            fan = RadialFan.solve(at: local, in: field, count: tiles.count)
        }
        Haptics.fire(.tap)
    }

    private func move(to point: CGPoint, in frame: CGRect) {
        guard let fan else { return }
        let local = CGPoint(x: point.x - frame.minX, y: point.y - frame.minY)
        let next = fan.index(at: local)
        guard next != highlighted else { return }
        highlighted = next
        if next != nil { Haptics.fire(.selection) }
    }

    private func commit() {
        let chosen = highlighted.map { tiles[$0] }
        highlighted = nil
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
            fan = nil
        }
        guard let chosen else { return }
        Haptics.fire(.success)
        onSelect(chosen)
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
