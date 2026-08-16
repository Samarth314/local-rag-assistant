import CoreGraphics
import OSLog

/// Diagnostics for the one bug on this screen that keeps coming back.
///
///     log stream --device --predicate 'subsystem == "com.ataru.client" AND category == "keyboard"' --level debug
///
/// The `.debug` level is never written to the persisted log, so this costs
/// nothing when nobody is streaming, and it means the next report about the
/// composer is one command away instead of another guess.
let keyboardLog = Logger(subsystem: "com.ataru.client", category: "keyboard")

/// How tall each block of the Ask screen is allowed to be, given the height
/// the keyboard has left behind.
///
/// ## The bug this exists to end
///
/// "I can't see the field I'm typing into because the keyboard still fully
/// blocks the text field" - reported twice, and the second time against a fix
/// that had been verified by building.
///
/// The measurement was never the problem. `KeyboardInset` reports the real
/// keyboard frame and the column really was framed to `height - overlap`. The
/// problem was arithmetic: the screen's FIXED blocks add up to more than the
/// height that is left. A 260pt orb, a 92pt status line, a 52pt composer and a
/// 140pt transcript come to roughly 604pt before any spacing, against about
/// 394pt of usable height on a 6.3" phone with the keyboard up. A SwiftUI
/// frame does not clip, so the column simply overflowed its own frame and the
/// bottom of it - the composer - was drawn underneath the keyboard. Shrinking
/// the frame was never going to help while the contents could not fit inside
/// it. Something has to give, and this decides what.
///
/// ## The priority, and it is not negotiable
///
/// 1. **The composer.** It is what the keyboard is attached to. If it is not
///    visible, the screen is broken, whatever else is on it.
/// 2. **The status line**, which loses its secondary line first and keeps the
///    phase label.
/// 3. **The orb**, which shrinks from 260 all the way to nothing. It is the
///    app's identity object, and it is also the one thing on this screen that
///    is pure affordance while somebody is typing.
/// 4. **The transcript**, which takes whatever is left.
///
/// Pure arithmetic on purpose: it is unit-tested against every plausible
/// screen and keyboard height (`AskMetricsTests`), which is the check that
/// would have caught this the first time.
struct AskMetrics: Equatable {
    /// Side of the orb. Zero means it is not drawn at all.
    let orb: CGFloat
    /// Max height for the conversation. Zero means it is not drawn.
    let transcript: CGFloat
    /// Height for the phase label and its message line.
    let status: CGFloat
    let composer: CGFloat

    /// Below this an orb is a smudge rather than an object, so it goes.
    static let minimumOrb: CGFloat = 64
    /// The orb's natural size, from the kit.
    static let fullOrb: CGFloat = 260
    /// Label plus the message line under it.
    static let fullStatus: CGFloat = 92
    /// Label only - what the status line falls back to when the screen is
    /// short. The phase is the half that matters; the hint under it is the
    /// half that does not.
    static let compactStatus: CGFloat = 46
    /// The composer's own height (`Theme.minHitTarget + 8`).
    static let composerHeight: CGFloat = 52
    /// Everything the stack spends on padding and spacing between blocks.
    /// Measured from the layout rather than guessed: three 20pt gaps and the
    /// screen's top padding.
    static let chrome: CGFloat = 60

    var contentHeight: CGFloat { orb + transcript + status + composer }
    var showsOrb: Bool { orb >= Self.minimumOrb }
    var showsTranscript: Bool { transcript > 0 }
    var showsStatusMessage: Bool { status >= Self.fullStatus }

    /// The single-column layout.
    ///
    /// - Parameters:
    ///   - available: height left after the keyboard, already measured.
    ///   - focused: whether the composer owns the keyboard.
    ///   - hasExchanges: whether there is a conversation to show at all.
    ///   - scale: the user's Dynamic Type scale, so a larger body size buys a
    ///     taller composer and status line rather than clipping them. Passed in
    ///     from a `@ScaledMetric` rather than read here, because this type is
    ///     deliberately free of SwiftUI and therefore testable.
    static func portrait(available: CGFloat, focused: Bool,
                         hasExchanges: Bool, scale: CGFloat = 1) -> AskMetrics {
        var budget = max(0, available - chrome)
        let scale = min(max(scale, 1), 2.4)

        // 1. The composer, always and first. It grows with the text inside it:
        // at accessibility sizes a fixed 52pt box clips its own field, which
        // is the same bug as the keyboard covering it, arrived at differently.
        let composer = min(composerHeight * scale, budget)
        budget -= composer

        // 2. The status line, compact when the screen is short.
        let wantStatus = budget < 150 * scale ? compactStatus * scale
                                              : fullStatus * scale
        let status = min(wantStatus, budget)
        budget -= status

        // 3 and 4. The orb keeps a floor while there is room for one, and the
        // transcript takes what is left over. While typing the orb yields
        // first: he is reading his own words, not watching it breathe.
        let wantTranscript: CGFloat = hasExchanges ? (focused ? 140 : 260)
                                                   : (focused ? 0 : 120)
        let orbFloor: CGFloat = focused ? 72 : 140
        let transcript = min(wantTranscript, max(0, budget - orbFloor))
        var orb = min(fullOrb, budget - transcript)
        if orb < minimumOrb { orb = 0 }

        return AskMetrics(orb: orb, transcript: transcript,
                          status: status, composer: composer)
    }

    /// Landscape, where the orb and the status sit in their own column beside
    /// the conversation and the composer.
    ///
    /// The two columns are independent, so this solves the LEFT one - the orb
    /// and its label - and the right column's composer is pinned to the bottom
    /// of a stack that fits by construction.
    static func landscape(available: CGFloat, focused: Bool,
                          scale: CGFloat = 1) -> AskMetrics {
        var budget = max(0, available - 24)
        let scale = min(max(scale, 1), 2.4)
        let status = min((focused ? compactStatus : fullStatus) * scale, budget)
        budget -= status
        var orb = min(190, budget)
        if orb < minimumOrb { orb = 0 }
        return AskMetrics(orb: orb, transcript: 0, status: status,
                          composer: composerHeight * scale)
    }
}
