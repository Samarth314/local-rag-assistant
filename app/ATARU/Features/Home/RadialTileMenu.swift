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

/// Hold, sweep a thumb, release to choose.
///
/// ## Why a ring rather than a menu
///
/// A tap-then-tap menu costs two deliberate acts and a look. This costs one
/// press you never lift: options fan out under the thumb already touching the
/// screen, and the choice is made by *where you let go*. Nothing is committed
/// until release, so sliding back to the centre cancels — the gesture is
/// reversible right up to the last moment, which is what makes it safe to
/// explore blind.
///
/// It collapses to a single circle at rest because a launcher that is always
/// open is just a menu bar. The point is that the app looks like almost
/// nothing until you reach for it.
struct RadialTileMenu: View {
    /// Owned by the parent so it can dim the app behind the fan — a scrim
    /// drawn from in here could not extend past this view's bounds.
    @Binding var isOpen: Bool
    let onSelect: (HomeTile) -> Void

    /// Opened by a tap rather than a hold, so it stays put and the tiles can be
    /// tapped individually. Holding and sweeping is the fast path; this is the
    /// one that works when you are not already committed to a direction, and
    /// the one VoiceOver and Switch Control can actually reach.
    @State private var isLatched = false
    @State private var highlighted: HomeTile?
    /// Distinguishes a sweep from a tap: a gesture that never left the dead
    /// zone was a tap, whatever its duration.
    @State private var didSweep = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Two rings now that every surface is present: eight core tiles close
    /// in, the rest of the homelab on an outer arc. 114/176 is the largest
    /// pair that keeps both arcs on a phone with the dial bottom-centre.
    private let innerRadius: Double = 114
    private let outerRadius: Double = 176
    /// Ignore travel this small: a press always wobbles a little, and a wobble
    /// is not a choice.
    private let deadZone: CGFloat = 34

    private var tiles: [HomeTile] { HomeTile.allCases }

    /// How far the dial sits above the bottom edge. The fan is laid out from
    /// the same anchor, so both stay put as it opens.
    ///
    /// Small, because the dial now stands where the tab bar stood: it is the
    /// app's only permanent navigation, so it belongs in the band the eye
    /// already goes to, not floating above it.
    private let bottomInset: CGFloat = 6

    /// Vertical space screens should leave clear at the bottom, so their
    /// content does not slide under the dial. This is the tab bar's old job,
    /// and roughly its old height.
    static let reservedHeight: CGFloat = 76

    var body: some View {
        // Full-screen and anchored to the bottom centre, rather than a box
        // that grows when the fan opens. A resizing frame pushed the dial out
        // of place and ran tiles off screen — and hit-testing is clipped to a
        // view's bounds, so a small frame could never let the tiles be tapped
        // however far outside they were drawn.
        //
        // Nothing here paints a background, so the empty area stays
        // untouchable and the app underneath keeps working normally.
        ZStack(alignment: .bottom) {
            if isOpen {
                ForEach(Array(tiles.enumerated()), id: \.element.id) { index, tile in
                    TileBubble(tile: tile, isHighlighted: highlighted == tile)
                        .offset(offset(for: index))
                        .padding(.bottom, bottomInset)
                        // Tappable only when latched; during a sweep the choice
                        // comes from the drag's direction, not from hit-testing.
                        .allowsHitTesting(isLatched)
                        .onTapGesture {
                            close()
                            Haptics.fire(.success)
                            onSelect(tile)
                        }
                        .transition(.scale(scale: 0.2).combined(with: .opacity))
                }
            }

            centerButton
                .padding(.bottom, bottomInset)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    private var centerButton: some View {
        Circle()
            .fill(Ataru.metal)
            .overlay { Circle().strokeBorder(Theme.cyanSubdued, lineWidth: 1) }
            .overlay {
                Image(systemName: isOpen ? "circle.grid.3x3.fill" : "circle.grid.3x3")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(Theme.cyan)
            }
            .frame(width: 64, height: 64)
            .shadow(color: .black.opacity(0.35), radius: 14, y: 8)
            .scaleEffect(isOpen ? 0.86 : 1)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !isOpen { open() }
                        update(for: value.translation)
                    }
                    .onEnded { _ in commit() }
            )
            // A shape with a gesture, not a Button, so the trait and the
            // identifier have to be stated: without them it is invisible to
            // Switch Control and to UI tests alike.
            .accessibilityElement()
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("open-menu")
            .accessibilityLabel("Open menu")
            .accessibilityHint("Hold and slide to a destination, then release.")
            // VoiceOver cannot sweep, so every destination is offered as a
            // plain action instead of leaving the menu unreachable.
            .accessibilityActions {
                ForEach(tiles) { tile in
                    Button(tile.title) { onSelect(tile) }
                }
            }
    }

    // MARK: - Geometry

    /// Two half-circle arcs above the dial: the first eight tiles on the
    /// inner ring, the rest on the outer. Both use the full 180 degrees;
    /// nothing fans downward, where a hand would cover it.
    private func offset(for index: Int) -> CGSize {
        let ring = index < 8 ? 0 : 1
        let indexInRing = ring == 0 ? index : index - 8
        let count = ring == 0 ? min(tiles.count, 8) : tiles.count - 8
        let radius = ring == 0 ? innerRadius : outerRadius
        let spread = Double.pi                 // left, over the top, to right
        let start = -Double.pi                 // straight left
        let step = count > 1 ? spread / Double(count - 1) : 0
        let angle = start + step * Double(indexInRing)
        return CGSize(width: radius * cos(angle), height: radius * sin(angle))
    }

    /// Nearest bubble to the thumb, by straight-line distance - with two
    /// rings, matching by angle alone cannot tell inner from outer.
    private func tile(nearest translation: CGSize) -> HomeTile? {
        let distance = hypot(translation.width, translation.height)
        guard distance > deadZone else { return nil }

        return tiles.indices.min { lhs, rhs in
            bubbleDistance(translation, to: lhs) < bubbleDistance(translation, to: rhs)
        }.map { tiles[$0] }
    }

    private func bubbleDistance(_ translation: CGSize, to index: Int) -> Double {
        let target = offset(for: index)
        return hypot(Double(translation.width) - Double(target.width),
                     Double(translation.height) - Double(target.height))
    }

    // MARK: - Gesture

    private func open() {
        withAnimation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.75)) {
            isOpen = true
        }
        Haptics.fire(.tap)
    }

    private func update(for translation: CGSize) {
        let next = tile(nearest: translation)
        if next != nil { didSweep = true }
        guard next != highlighted else { return }
        highlighted = next
        if next != nil { Haptics.fire(.selection) }
    }

    private func commit() {
        let chosen = highlighted
        let swept = didSweep
        didSweep = false
        highlighted = nil

        // A press that never swept was a tap: leave the fan up so the tiles can
        // be read and tapped, instead of flashing open and shut.
        guard swept else {
            if isLatched { close() } else { isLatched = true }
            return
        }

        close()
        guard let chosen else { return }
        Haptics.fire(.success)
        onSelect(chosen)
    }

    private func close() {
        withAnimation(reduceMotion ? nil : .spring(response: 0.26, dampingFraction: 0.8)) {
            isOpen = false
        }
        isLatched = false
        highlighted = nil
    }
}

/// One option in the fan.
private struct TileBubble: View {
    let tile: HomeTile
    let isHighlighted: Bool

    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: tile.symbol)
                .font(.system(size: 13, weight: .light))
            Text(tile.title)
                .font(.system(size: 7.5, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .foregroundStyle(foreground)
        .frame(width: 48, height: 48)
        .background(Ataru.metal, in: Circle())
        .overlay {
            Circle().strokeBorder(
                isHighlighted ? Theme.cyan : Theme.border,
                lineWidth: isHighlighted ? 1.5 : 1
            )
        }
        .shadow(color: .black.opacity(0.3), radius: 10, y: 6)
        .scaleEffect(isHighlighted ? 1.12 : 1)
        .animation(.spring(response: 0.2, dampingFraction: 0.7), value: isHighlighted)
        // Exposed rather than hidden. The dial's own accessibilityActions
        // cover VoiceOver, but Switch Control and UI tests drive real elements
        // — and a launcher only reachable by sweeping a thumb is reachable by
        // neither.
        .accessibilityElement()
        .accessibilityLabel(tile.title)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("tile-\(tile.rawValue)")
    }

    private var foreground: Color {
        isHighlighted ? Theme.cyan : Theme.textSecondary
    }
}
