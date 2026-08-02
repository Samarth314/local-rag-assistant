import SwiftUI

/// One place ATARU can take you.
///
/// Mirrors the tiles on the desktop home page, minus the ones that open native
/// apps — an iPhone reaches Infuse or Bitwarden from its own Home Screen, and
/// duplicating those here would be a menu of links to other icons.
enum HomeTile: String, CaseIterable, Identifiable {
    case assistant, documents, finances, health, personal, system

    var id: String { rawValue }

    var title: String {
        switch self {
        case .assistant: return "Ask"
        case .documents: return "Documents"
        case .finances: return "Finances"
        case .health:    return "Health"
        case .personal:  return "Personal"
        case .system:    return "System"
        }
    }

    /// The one-line subtitle from the desktop tiles, so the two read as the
    /// same product rather than two apps that happen to share a name.
    var caption: String {
        switch self {
        case .assistant: return "Ask anything"
        case .documents: return "Browse · search"
        case .finances:  return "Net worth · spend"
        case .health:    return "Labs · meds"
        case .personal:  return "Vault entries"
        case .system:    return "Orin health"
        }
    }

    var symbol: String {
        switch self {
        case .assistant: return "waveform"
        case .documents: return "tray.full"
        case .finances:  return "dollarsign.circle"
        case .health:    return "heart.text.square"
        case .personal:  return "person.crop.circle"
        case .system:    return "cpu"
        }
    }

    /// Whether the app can actually show this yet. The rest are on the server
    /// but have no phone screen — offering them as if they worked would be a
    /// menu that lies.
    var isAvailable: Bool {
        switch self {
        case .assistant, .documents, .system: return true
        case .finances, .health, .personal:   return false
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

    /// How far the tiles sit from the centre of the button.
    private let radius: CGFloat = 200
    /// Ignore travel this small: a press always wobbles a little, and a wobble
    /// is not a choice.
    private let deadZone: CGFloat = 34

    private var tiles: [HomeTile] { HomeTile.allCases }

    /// How far the button sits from the trailing and bottom edges. The fan is
    /// laid out from the same anchor, so both stay put as the fan opens.
    private let edgeInset = CGSize(width: 18, height: 70)

    var body: some View {
        // Full-screen and anchored bottom-trailing, rather than a box that
        // grows when the fan opens. A resizing frame pushed the launcher out of
        // its corner and ran the tiles off the left edge — and hit-testing is
        // clipped to a view's bounds, so a small frame could never let the
        // tiles be tapped however far outside they were drawn.
        //
        // Nothing here paints a background, so the empty area stays
        // untouchable and the app underneath keeps working normally.
        ZStack(alignment: .bottomTrailing) {
            if isOpen {
                ForEach(Array(tiles.enumerated()), id: \.element.id) { index, tile in
                    TileBubble(tile: tile, isHighlighted: highlighted == tile)
                        .offset(offset(for: index))
                        .padding(.trailing, edgeInset.width)
                        .padding(.bottom, edgeInset.height)
                        // Tappable only when latched; during a sweep the choice
                        // comes from the drag's direction, not from hit-testing.
                        .allowsHitTesting(isLatched)
                        .onTapGesture {
                            guard tile.isAvailable else { return }
                            close()
                            Haptics.fire(.success)
                            onSelect(tile)
                        }
                        .transition(.scale(scale: 0.2).combined(with: .opacity))
                }
            }

            centerButton
                .padding(.trailing, edgeInset.width)
                .padding(.bottom, edgeInset.height)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
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
            .accessibilityLabel("Open menu")
            .accessibilityHint("Hold and slide to a destination, then release.")
            // VoiceOver cannot sweep, so every destination is offered as a
            // plain action instead of leaving the menu unreachable.
            .accessibilityActions {
                ForEach(tiles.filter(\.isAvailable)) { tile in
                    Button(tile.title) { onSelect(tile) }
                }
            }
    }

    // MARK: - Geometry

    /// Fans up and to the left, into the empty quadrant.
    ///
    /// The launcher sits in the bottom-right corner, so a full ring would put
    /// half the tiles off screen and the rest under the palm. A quarter-turn
    /// arc opening away from the corner keeps every tile both visible and
    /// inside the sweep of one thumb, and lands them on empty backdrop rather
    /// than on top of the text field.
    private func offset(for index: Int) -> CGSize {
        let count = max(tiles.count, 1)
        // A quarter turn, from straight left to straight up. Wider would push
        // tiles past the right edge — the launcher sits ~50pt from it — and
        // narrower would overlap them: six 58pt bubbles need about 63pt of arc
        // each, which is what 90 degrees at this radius buys.
        let spread = Double.pi * 0.5
        let start = -Double.pi                 // straight left
        let step = count > 1 ? spread / Double(count - 1) : 0
        let angle = start + step * Double(index)
        return CGSize(width: radius * cos(angle), height: radius * sin(angle))
    }

    private func tile(nearest translation: CGSize) -> HomeTile? {
        let distance = hypot(translation.width, translation.height)
        guard distance > deadZone else { return nil }

        // Angle of travel, matched to the nearest tile's angle. Chosen by
        // direction rather than by proximity to a bubble's centre, so a short
        // decisive flick selects as reliably as a long careful reach.
        let angle = atan2(translation.height, translation.width)
        return tiles.enumerated().min { lhs, rhs in
            angularDistance(angle, angleFor: lhs.offset) <
            angularDistance(angle, angleFor: rhs.offset)
        }?.element
    }

    private func angleFor(_ index: Int) -> Double {
        let size = offset(for: index)
        return atan2(size.height, size.width)
    }

    private func angularDistance(_ a: Double, angleFor index: Int) -> Double {
        var delta = abs(a - angleFor(index))
        if delta > .pi { delta = 2 * .pi - delta }
        return delta
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
        // Unavailable tiles are shown but not selectable: seeing what is coming
        // is useful, being dropped on an empty screen is not.
        guard let chosen, chosen.isAvailable else { return }
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
                .font(.system(size: 15, weight: .light))
            Text(tile.title)
                .font(.system(size: 8.5, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .foregroundStyle(foreground)
        .frame(width: 58, height: 58)
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
        .accessibilityHidden(true)
    }

    private var foreground: Color {
        if !tile.isAvailable { return Theme.textTertiary }
        return isHighlighted ? Theme.cyan : Theme.textSecondary
    }
}
