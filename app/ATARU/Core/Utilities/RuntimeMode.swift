import Foundation

/// Whether this process is being driven by the UI test suite.
///
/// Set by the `-ATARUUITesting` launch argument. Two things depend on it, for
/// different reasons: `AppState` swaps in a throwaway defaults suite so a run
/// never inherits the last server the simulator was pointed at, and `OrbView`
/// stops animating - see there for why that one is not cosmetic.
enum RuntimeMode {

    /// DEBUG ONLY, AND DELIBERATELY AT COMPILE TIME.
    ///
    /// A shipped app that honours this argument is a shipped app that can be
    /// talked out of its Keychain token and its saved server address by
    /// whoever gets to choose its launch arguments. Gating it on an
    /// environment variable the test runner sets would read the same way, but
    /// it would still be a runtime check sitting in the Release binary,
    /// deciding on input from outside the app. `#if DEBUG` is the stronger
    /// answer: in a Release build there is no check to pass, because there is
    /// no branch - the flag is the constant `false` and every `guard` on it is
    /// dead code the optimiser removes.
    ///
    /// The scheme builds its test action in Debug (see `project.yml`), so the
    /// UI suite is unaffected.
    #if DEBUG
    static let isUITesting = ProcessInfo.processInfo.arguments.contains("-ATARUUITesting")
    #else
    static let isUITesting = false
    #endif

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
    /// The name a retired tile answers to, so a suite (or anything else that
    /// names a destination from outside) does not silently reach nowhere.
    /// `cards` was its own tile until the Finance pager absorbed it.
    static var startTile: HomeTile? {
        guard isUITesting,
              let raw = UserDefaults.standard.string(forKey: "ATARUUIStartTile")
        else { return nil }
        if raw == FinanceRoute.retiredCardsTile {
            FinanceRoute.record(.cards)
            return .finance
        }
        return HomeTile(rawValue: raw)
    }
}
