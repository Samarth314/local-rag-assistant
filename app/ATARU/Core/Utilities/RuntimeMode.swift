import Foundation

/// Whether this process is being driven by the UI test suite.
///
/// Set by the `-ATARUUITesting` launch argument. Two things depend on it, for
/// different reasons: `AppState` swaps in a throwaway defaults suite so a run
/// never inherits the last server the simulator was pointed at, and `OrbView`
/// stops animating — see there for why that one is not cosmetic.
enum RuntimeMode {
    static let isUITesting = ProcessInfo.processInfo.arguments.contains("-ATARUUITesting")

    /// A tile to open on launch, named by its raw value. UI suite only, and
    /// ignored entirely in any other run.
    ///
    /// This exists because the app has exactly two ways between screens and
    /// XCUITest can drive neither. The radial launcher takes its touches from
    /// a window recogniser and never participates in hit-testing, so there is
    /// nothing there to tap; the accessible route is a set of named
    /// accessibility actions on the Ask orb, and XCUIElement has no API for
    /// invoking a custom action. The navigation-bar menu that used to be the
    /// third way is gone on purpose (see `TileDestinations`).
    ///
    /// So the suite is handed a starting screen rather than a route to it,
    /// which is honest about what it is testing: the Library page's own
    /// behaviour, not the way in.
    static var startTile: HomeTile? {
        guard isUITesting,
              let raw = UserDefaults.standard.string(forKey: "ATARUUIStartTile")
        else { return nil }
        return HomeTile(rawValue: raw)
    }
}
