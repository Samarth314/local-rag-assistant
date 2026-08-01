import SwiftUI

/// Semantic names for the ATARU UI kit's tokens.
///
/// Every value here forwards to `Ataru`, which is vendored verbatim from the
/// kit. Nothing in this file may define a colour of its own — the point is that
/// there is exactly one place a hex value exists, and it is the file that gets
/// replaced wholesale when the kit changes.
///
/// This layer exists because the app talks about "surface" and "border" while
/// the kit talks about "panel" and "line". Mapping once here beats renaming
/// every call site whenever the kit's vocabulary shifts.
enum Theme {

    // MARK: - Surfaces

    /// Flat background colour. Prefer `.ataruBackdrop()` at the root — the kit
    /// is explicit that the flat colour reads deader than the radial gradient.
    static let canvas = Ataru.Palette.bg
    static let backgroundElevated = Ataru.Palette.panel
    static let surface = Ataru.Palette.panel
    static let surfaceElevated = Ataru.Palette.panel2
    /// Hairline border: white at 7%, not a solid grey.
    static let border = Ataru.Palette.line
    /// The stronger border, for pressed and focused states.
    static let borderStrong = Ataru.Palette.line2

    // MARK: - Text

    static let textPrimary = Ataru.Palette.text
    static let textSecondary = Ataru.Palette.muted
    static let textTertiary = Ataru.Palette.faint

    // MARK: - Accents
    //
    // One accent. The kit is emphatic about this: a second hue competes with
    // the orb, which is the only thing that should read as "the system is
    // doing something".

    static let cyan = Ataru.Palette.accent
    static let cyanSubdued = Ataru.Palette.accentDim
    /// Fill behind a selected chip or a focus ring.
    static let accentSoft = Ataru.Palette.accentSoft
    /// Foreground on top of an accent fill. Never `canvas`.
    static let onAccent = Ataru.Palette.onAccent

    static let green = Ataru.Palette.ok
    static let amber = Ataru.Palette.warn
    static let red = Ataru.Palette.err

    // MARK: - Geometry

    enum Radius {
        static let small = Ataru.Radius.chip        // 7
        static let tile = Ataru.Radius.tile         // 14
        static let card = Ataru.Radius.bubble       // 18
        static let modal = Ataru.Radius.modal       // 20
        static let large = Ataru.Radius.composer    // 24
    }

    enum Space {
        static let xxs = Ataru.Space.xs             // 4
        static let xs = Ataru.Space.sm              // 8
        static let s = Ataru.Space.md               // 12
        static let m = Ataru.Space.gutter           // 18
        static let l = Ataru.Space.lg               // 20
        static let xl = Ataru.Space.xl              // 26
        static let xxl: CGFloat = 48
        /// Standard horizontal inset for phone layouts.
        static let screen = Ataru.Space.gutter      // 18
    }

    /// Minimum tappable dimension (HIG). The kit's 38pt control button is the
    /// visual size; the hit target around it still has to reach 44.
    static let minHitTarget: CGFloat = 44
    static let controlButton = Ataru.Size.controlButton
    static let statusDot = Ataru.Size.statusDot
}

extension SemanticTone {
    /// Resolves a model-layer tone to a palette colour.
    ///
    /// The models describe *meaning* ("this is a warning") and stay free of
    /// SwiftUI; the mapping to an actual colour belongs here with the rest of
    /// the palette, so a retune never has to touch a model.
    var color: Color {
        switch self {
        case .green: return Theme.green
        case .cyan: return Theme.cyan
        case .amber: return Theme.amber
        case .red: return Theme.red
        }
    }
}
