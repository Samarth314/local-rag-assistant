//
//  AtaruTheme.swift
//  ATARU UI kit - design tokens for the iOS app.
//
//  VENDORED VERBATIM from https://dev.ataru.aryasasikumar.com/uikit/swift/AtaruTheme.swift
//  Do not hand-edit. If the kit changes, replace this file wholesale; local
//  edits would silently drift the app away from the web chat app, which is the
//  actual source of truth (see the header note below).
//
//  Mirrors ataru-build/chat/web/style.css. That stylesheet is the source of
//  truth; if the two ever disagree, the stylesheet wins.
//
//  Pure SwiftUI + Foundation on purpose - no UIKit - so it compiles for iOS,
//  macOS and previews alike.
//
//  Usage:
//      Text("ATARU").ataruStyle(.brand)
//      RoundedRectangle(cornerRadius: Ataru.Radius.composer).fill(Ataru.metal)
//

import SwiftUI

public enum Ataru {

    // MARK: - Color
    //
    // One accent, and only one. The palette is deliberately near-monochrome so
    // the cyan reads as "the system is doing something". Resist adding a second
    // hue: if something needs to stand out, it competes with the orb.

    public enum Palette {
        /// App background. Use `Ataru.backdrop` for the real thing - the flat
        /// colour alone is noticeably deader than the radial gradient.
        public static let bg          = Color(hex: 0x090A0C)
        /// Raised surface: composer card.
        public static let panel       = Color(hex: 0x14171D)
        /// Toast, pressed ghost button.
        public static let panel2      = Color(hex: 0x1B1F26)

        public static let text        = Color(hex: 0xDFE4EA)
        public static let muted       = Color(hex: 0x8B95A3)
        public static let faint       = Color(hex: 0x4A4F58)

        /// The accent. Send button, links, and the orb's tint.
        public static let accent      = Color(hex: 0x8FD3E6)
        /// Hover/highlight variant - on iOS use for the pressed send button.
        public static let accentHover = Color(hex: 0xA5DFEE)

        public static let ok          = Color(hex: 0x79DCA0)
        public static let warn        = Color(hex: 0xE6C079)
        /// Recording, "End call", failures.
        public static let err         = Color(hex: 0xE28A8A)

        /// Foreground ON an accent or err fill. Never use `bg` for this.
        public static let onAccent    = Color(hex: 0x0A0D10)

        // Alpha-on-surface tokens.
        public static let line        = Color.white.opacity(0.07)
        public static let line2       = Color.white.opacity(0.13)
        public static let accentDim   = accent.opacity(0.50)
        public static let accentSoft  = accent.opacity(0.12)
        public static let codeFill    = Color.white.opacity(0.06)
        /// The 1px top highlight that makes cards look milled rather than flat.
        public static let innerTop    = Color.white.opacity(0.04)
    }

    // MARK: - Gradients

    /// Agent bubbles, mic button, file tiles, modal panels.
    /// CSS `150deg` measures clockwise from "up"; in SwiftUI that lands as
    /// roughly topLeading -> bottomTrailing.
    public static let metal = LinearGradient(
        stops: [
            .init(color: Color(hex: 0x1A1D23), location: 0.00),
            .init(color: Color(hex: 0x111318), location: 0.55),
            .init(color: Color(hex: 0x0C0E12), location: 1.00),
        ],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )

    /// User bubbles - the same metal, pulled a few degrees toward the accent.
    public static let user = LinearGradient(
        stops: [
            .init(color: Color(hex: 0x1C2A31), location: 0.0),
            .init(color: Color(hex: 0x151F25), location: 1.0),
        ],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )

    /// The app background. Anchored above the top edge so the light appears to
    /// come from off-screen. Pin it behind everything and never let it scroll.
    public static let backdrop = RadialGradient(
        stops: [
            .init(color: Color(hex: 0x15181D), location: 0.00),
            .init(color: Color(hex: 0x0A0B0D), location: 0.55),
            .init(color: Color(hex: 0x060708), location: 1.00),
        ],
        center: UnitPoint(x: 0.5, y: -0.2),
        startRadius: 0,
        endRadius: 900
    )

    /// Scrim behind the call overlay. Put a 14pt blur under it.
    public static let callBackdrop = RadialGradient(
        stops: [
            .init(color: Color(hex: 0x15181D).opacity(0.97), location: 0.0),
            .init(color: Color(hex: 0x090A0C).opacity(0.98), location: 0.6),
        ],
        center: UnitPoint(x: 0.5, y: -0.2),
        startRadius: 0,
        endRadius: 900
    )

    // MARK: - Metrics

    public enum Radius {
        public static let bubble: CGFloat     = 18
        /// The tail corner on a speech bubble - collapses toward the sender.
        public static let bubbleTail: CGFloat = 6
        public static let composer: CGFloat   = 24
        public static let modal: CGFloat      = 20
        public static let tile: CGFloat       = 14
        public static let chip: CGFloat       = 7
        /// Use `Capsule()` in SwiftUI rather than this literal where you can.
        public static let pill: CGFloat       = 999
    }

    public enum Space {
        public static let xs: CGFloat     = 4
        public static let sm: CGFloat     = 8
        public static let md: CGFloat     = 12
        public static let lg: CGFloat     = 20
        public static let xl: CGFloat     = 26
        public static let gutter: CGFloat = 18
        /// Vertical gap between messages in the log.
        public static let logGap: CGFloat = 20
    }

    public enum Size {
        /// The log column never grows past this, however wide the screen.
        public static let maxContentWidth: CGFloat = 780
        public static let controlButton: CGFloat   = 38
        public static let statusDot: CGFloat       = 8
        public static let fileTile: CGFloat        = 118
        public static let greetOrb: CGFloat        = 84
    }

    public enum Motion {
        public static let micro: Double          = 0.15
        public static let pressScale: CGFloat    = 0.92
        public static let press: Double          = 0.08
        public static let thinkingDotCycle: Double   = 1.2
        public static let thinkingDotStagger: Double = 0.16
        public static let recordPulseCycle: Double   = 1.2
        public static let spinnerCycle: Double       = 0.9

        public static let blurTopbar: CGFloat    = 12
        public static let blurCallOverlay: CGFloat = 14
        public static let blurDocModal: CGFloat  = 8
    }

    // MARK: - Typography
    //
    // Weights run light. Nothing in this UI is bolder than semibold except the
    // all-caps micro labels, which need the weight to survive the tracking.

    public enum TextStyle {
        case brand, eyebrow, greeting, body, tag, meta
        case callState, callTranscript, callAnswer, hint, codeInline

        public var font: Font {
            switch self {
            case .brand:          return .system(size: 19,   weight: .ultraLight)
            case .eyebrow:        return .system(size: 10,   weight: .semibold)
            case .greeting:       return .system(size: 34,   weight: .thin)
            case .body:           return .system(size: 15.5, weight: .regular)
            case .tag:            return .system(size: 10,   weight: .bold)
            case .meta:           return .system(size: 11.5, weight: .regular)
            case .callState:      return .system(size: 11,   weight: .bold)
            case .callTranscript: return .system(size: 17,   weight: .light)
            case .callAnswer:     return .system(size: 14.5, weight: .regular)
            case .hint:           return .system(size: 11.5, weight: .regular)
            case .codeInline:     return .system(size: 11,   weight: .regular, design: .monospaced)
            }
        }

        /// SwiftUI tracking is in points, CSS letter-spacing here is in em.
        public var tracking: CGFloat {
            switch self {
            case .brand:          return 19 * 0.14
            case .eyebrow:        return 10 * 0.28
            case .greeting:       return 34 * 0.03
            case .tag:            return 10 * 0.14
            case .callState:      return 11 * 0.30
            case .callTranscript: return 17 * 0.01
            case .hint:           return 11.5 * 0.04
            case .body:           return 15.5 * 0.01
            default:              return 0
            }
        }

        public var color: Color {
            switch self {
            case .eyebrow, .hint:            return Palette.faint
            case .meta, .callState, .callAnswer: return Palette.muted
            case .tag:                       return Palette.accent
            case .codeInline:                return Color(hex: 0xAEB8C4)
            default:                         return Palette.text
            }
        }

        /// These render upper-cased with heavy tracking.
        public var isUppercased: Bool {
            switch self {
            case .eyebrow, .tag, .callState: return true
            default: return false
            }
        }
    }
}

// MARK: - View sugar

public extension View {
    /// Applies an ATARU text style (font + tracking + colour) in one call.
    func ataruStyle(_ style: Ataru.TextStyle) -> some View {
        self.font(style.font)
            .tracking(style.tracking)
            .foregroundStyle(style.color)
    }

    /// The full-bleed app background. Apply once, at the root.
    func ataruBackdrop() -> some View {
        self.background(Ataru.backdrop.ignoresSafeArea())
    }

    /// The milled-metal card treatment: gradient, hairline border, and the
    /// inset top highlight that keeps it from looking like flat grey.
    func ataruCard(radius: CGFloat = Ataru.Radius.bubble) -> some View {
        self
            .background(Ataru.metal, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Ataru.Palette.line, lineWidth: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .inset(by: 0.5)
                    .strokeBorder(
                        LinearGradient(
                            colors: [Ataru.Palette.innerTop, .clear],
                            startPoint: .top, endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: .black.opacity(0.25), radius: 14, y: 10)
    }
}

// MARK: - Hex helper

public extension Color {
    /// `Color(hex: 0x8FD3E6)` - sRGB, matching the CSS values exactly.
    init(hex: UInt32, opacity: Double = 1.0) {
        self.init(
            .sRGB,
            red:   Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8)  & 0xFF) / 255.0,
            blue:  Double(hex & 0xFF)         / 255.0,
            opacity: opacity
        )
    }
}
