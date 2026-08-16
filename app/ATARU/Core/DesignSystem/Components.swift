import SwiftUI

// MARK: - Card

/// The standard card.
///
/// The kit is specific about this: cards are the `metal` gradient, never a flat
/// fill, plus a hairline border and a 1px white-4% top highlight. That
/// highlight is what makes a card read as milled rather than as grey — it is
/// the detail that carries the whole surface treatment, so it is not optional.
///
/// Delegates to `.ataruCard()` so the anatomy lives in the vendored kit file
/// and cannot drift here.
struct ATCard<Content: View>: View {
    var radius: CGFloat = Theme.Radius.card
    /// Draws the accent border instead of the hairline. Reserved for the one
    /// element that currently has focus.
    var glow: Bool = false
    @ViewBuilder var content: Content

    var body: some View {
        content
            .ataruCard(radius: radius)
            .overlay {
                if glow {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(Theme.cyanSubdued, lineWidth: 1)
                }
            }
            .shadow(color: glow ? Theme.cyan.opacity(0.14) : .clear, radius: 18)
    }
}

// MARK: - Press feedback

/// What a tappable card does under a thumb.
///
/// `.buttonStyle(.plain)` is what these rows used, and plain means literally
/// nothing happens on touch-down: the row is inert until the navigation push
/// begins, so on a slow push the tap reads as having missed. A card that
/// gives slightly under the finger costs one modifier and is the difference
/// between an app that responds and an app that eventually reacts.
///
/// Deliberately small. 0.97 and a few percent of dimming is felt rather than
/// watched - anything more and a list of cards becomes a trampoline.
struct ATPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.88 : 1)
            .animation(.spring(response: 0.24, dampingFraction: 0.75),
                       value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == ATPressStyle {
    /// `.buttonStyle(.atPress)` - the app's tappable-card feedback.
    static var atPress: ATPressStyle { ATPressStyle() }
}

// MARK: - Hit targets

extension View {
    /// Grows what a finger has to hit to at least 44pt square, without growing
    /// what the eye sees.
    ///
    /// The glyph stays whatever size the design wants it: an 11pt xmark, a
    /// 20pt circle, a 15pt chevron in a 38pt disc. What changes is the frame
    /// around it, and `contentShape` is what makes that frame - rather than
    /// the glyph's own painted pixels - the thing taps land on. Without the
    /// shape a `frame` alone does nothing, because SwiftUI hit-tests the
    /// content.
    ///
    /// 44 is the HIG floor, and it is a floor rather than a preference: the
    /// pad of an adult index finger is about 45pt across, so a 14pt target is
    /// aimed at rather than touched.
    func hitTarget(_ side: CGFloat = Theme.minHitTarget) -> some View {
        frame(minWidth: side, minHeight: side)
            .contentShape(Rectangle())
    }
}

// MARK: - Status

/// Semantic status used by nodes, services and models.
enum StatusTone {
    case online, warning, failure, idle, unknown

    var color: Color {
        switch self {
        case .online: return Theme.green
        case .warning: return Theme.amber
        case .failure: return Theme.red
        case .idle: return Theme.cyanSubdued
        case .unknown: return Theme.textTertiary
        }
    }

    /// SF Symbol shown alongside colour so status is never colour-only.
    var symbol: String {
        switch self {
        case .online: return "circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .failure: return "xmark.octagon.fill"
        case .idle: return "moon.fill"
        case .unknown: return "questionmark.circle.fill"
        }
    }
}

/// A small status dot with an accessible text equivalent.
/// Never communicates state through colour alone: the adjacent label carries
/// the same information, and VoiceOver reads `label`.
struct StatusDot: View {
    let tone: StatusTone
    let label: String
    var showsLabel: Bool = true
    var pulses: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiate
    @State private var pulse = false

    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            Group {
                if differentiate {
                    Image(systemName: tone.symbol)
                        .font(.system(size: 9, weight: .bold))
                } else {
                    Circle().frame(width: Theme.statusDot, height: Theme.statusDot)
                }
            }
            .foregroundStyle(tone.color)
            .scaleEffect(pulse ? 1.28 : 1.0)
            .opacity(pulse ? 0.65 : 1.0)
            .onAppear {
                guard pulses, !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.9).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }

            if showsLabel {
                Text(label)
                    .font(.ataruCaption())
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }
}

/// Pill used for categories and states — the kit's `tag` style.
///
/// 10pt bold at 0.14em, upper-cased, on the accent-soft fill. The weight is
/// there to survive the tracking; at regular weight this size disappears.
struct ATPill: View {
    let text: String
    var tone: Color = Theme.cyan

    var body: some View {
        Text(text.uppercased())
            .font(Ataru.TextStyle.tag.font)
            .tracking(Ataru.TextStyle.tag.tracking)
            .foregroundStyle(tone)
            .padding(.horizontal, Ataru.Space.sm)
            .padding(.vertical, Ataru.Space.xs)
            .background { Capsule().fill(tone.opacity(0.12)) }
            .overlay { Capsule().strokeBorder(tone.opacity(0.28), lineWidth: 1) }
            .accessibilityLabel(text)
    }
}

// MARK: - States

/// Shared empty / error presentation so no screen ships a bare "Something went wrong".
struct ATStateView: View {
    let symbol: String
    let title: String
    let message: String
    var tone: Color = Theme.textSecondary
    var retry: (() -> Void)?

    var body: some View {
        VStack(spacing: Theme.Space.s) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .ultraLight))
                .foregroundStyle(tone)
            Text(title)
                .font(.ataruTitle())
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)
            Text(message)
                .ataruStyle(.meta)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let retry {
                Button("Try again", action: retry)
                    .buttonStyle(.bordered)
                    .tint(Theme.cyan)
                    .padding(.top, Theme.Space.xxs)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(Theme.Space.l)
        .accessibilityElement(children: .contain)
    }
}

/// Shimmer-free loading placeholder (calm, not busy).
struct ATSkeleton: View {
    var height: CGFloat = 14
    var width: CGFloat? = nil

    var body: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
            .fill(Theme.surfaceElevated)
            .frame(width: width, height: height)
            .accessibilityHidden(true)
    }
}

/// Banner explaining that content came from cache / the app is offline.
struct FreshnessBanner: View {
    let state: DataFreshness

    var body: some View {
        if let message = state.bannerMessage {
            HStack(spacing: Theme.Space.xs) {
                Image(systemName: state.bannerSymbol)
                    .font(.system(size: 11, weight: .semibold))
                Text(message)
                    .font(.ataruCaption())
                Spacer(minLength: 0)
            }
            .foregroundStyle(state.bannerTone.color)
            .padding(.horizontal, Theme.Space.s)
            .padding(.vertical, Theme.Space.xs)
            .background {
                RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                    .fill(state.bannerTone.color.opacity(0.10))
            }
            .accessibilityElement(children: .combine)
        }
    }
}

#Preview {
    ScrollView {
        VStack(spacing: 16) {
            ATCard { VStack { Text("Card").foregroundStyle(Theme.textPrimary) }.padding(24) }
            ATCard(glow: true) { VStack { Text("Glowing").foregroundStyle(Theme.textPrimary) }.padding(24) }
            HStack(spacing: 16) {
                StatusDot(tone: .online, label: "online", pulses: true)
                StatusDot(tone: .warning, label: "stale")
                StatusDot(tone: .failure, label: "offline")
            }
            HStack { ATPill(text: "health", tone: Theme.amber); ATPill(text: "work", tone: Theme.cyan) }
            FreshnessBanner(state: .stale(Date().addingTimeInterval(-3600)))
            ATStateView(symbol: "tray", title: "Nothing indexed yet",
                        message: "Documents you ingest on the vault will appear here.", retry: {})
        }
        .padding()
    }
    .ataruBackdrop()
}
