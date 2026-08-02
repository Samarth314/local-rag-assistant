import Foundation

/// Whether this process is being driven by the UI test suite.
///
/// Set by the `-ATARUUITesting` launch argument. Two things depend on it, for
/// different reasons: `AppState` swaps in a throwaway defaults suite so a run
/// never inherits the last server the simulator was pointed at, and `OrbView`
/// stops animating — see there for why that one is not cosmetic.
enum RuntimeMode {
    static let isUITesting = ProcessInfo.processInfo.arguments.contains("-ATARUUITesting")
}
