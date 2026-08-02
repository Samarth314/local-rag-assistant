import SwiftUI

/// How any screen asks to be replaced by another one.
///
/// Routing lives in `RootView` — it owns which tab is showing and which tile
/// is presented — but the controls that trigger it are scattered across
/// screens that have no business taking a closure for it. The environment
/// carries it instead, so a navigation bar button anywhere can navigate.
private struct OpenTileKey: EnvironmentKey {
    static let defaultValue: (HomeTile) -> Void = { _ in }
}

extension EnvironmentValues {
    var openTile: (HomeTile) -> Void {
        get { self[OpenTileKey.self] }
        set { self[OpenTileKey.self] = newValue }
    }
}

/// The destinations, as a plain menu.
///
/// ## Why this exists at all
///
/// The radial launcher is a press-and-sweep gesture, and a press-and-sweep
/// gesture is unusable by VoiceOver and Switch Control, undiscoverable by
/// anyone who has not been told about it, and undrivable by a UI test. With
/// the tab bar gone it is also the *only* way between screens — so without
/// this button, a whole class of user would be locked into whichever screen
/// the app launched on.
///
/// It is one glyph in a navigation bar that was otherwise empty. That is the
/// entire cost, and it buys the app back its floor.
struct TileDestinationsMenu: View {
    @Environment(\.openTile) private var openTile

    var body: some View {
        Menu {
            ForEach(HomeTile.allCases) { tile in
                Button {
                    openTile(tile)
                } label: {
                    Label(tile.title, systemImage: tile.symbol)
                }
            }
        } label: {
            Image(systemName: "circle.grid.3x3")
        }
        .accessibilityIdentifier("open-menu")
        .accessibilityLabel("Destinations")
        .accessibilityHint("Or hold anywhere on the screen and sweep.")
    }
}
