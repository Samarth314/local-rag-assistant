import SwiftUI

/// How any screen asks to be replaced by another one.
///
/// Routing lives in `RootView` — it owns which tile is presented — but the
/// controls that trigger it are scattered across screens that have no business
/// taking a closure for it. The environment carries it instead, so anything
/// anywhere can navigate.
///
/// ## What used to be here
///
/// `TileDestinationsMenu`: a grid glyph in the navigation bar that dropped
/// down every `HomeTile`. It existed because the radial launcher is a
/// press-and-sweep gesture, which VoiceOver and Switch Control cannot drive —
/// so with the tab bar gone it was the accessible floor, and it was documented
/// as not to be removed.
///
/// It is removed. The floor moved rather than disappearing: the Ask orb now
/// carries the same set as named accessibility actions, built from the same
/// enum (see `VoiceView.orbControl`). What that buys is a navigation bar with
/// nothing in it at all — the launcher is a held thumb anywhere on the glass,
/// and a permanent control advertising a second way to do it was the last
/// piece of chrome on the app's front page.
private struct OpenTileKey: EnvironmentKey {
    static let defaultValue: (HomeTile) -> Void = { _ in }
}

extension EnvironmentValues {
    var openTile: (HomeTile) -> Void {
        get { self[OpenTileKey.self] }
        set { self[OpenTileKey.self] = newValue }
    }
}
