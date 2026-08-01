import Intents
import SwiftUI
import UIKit

/// Catches a call request that arrives before any view exists.
///
/// Tapping ATARU in the Phone app's Recents cold launches the app straight
/// into an `INStartCallIntent`. That activity can be delivered before
/// `RootView` has appeared, and a view modifier that is not installed yet
/// cannot receive it — which shows up as the app opening and then just sitting
/// there, waiting for the user to start the call by hand. That is precisely the
/// failure this exists to prevent.
///
/// The app delegate is guaranteed to be alive at launch, so it records the
/// request and `RootView` drains it as soon as it appears.
@MainActor
enum PendingCallRequest {
    private static var isPending = false

    static func record() { isPending = true }

    /// Returns true once per recorded request, so a call is placed exactly once
    /// however many delivery routes fired.
    static func take() -> Bool {
        defer { isPending = false }
        return isPending
    }
}

/// Exists only to catch launch-time call intents — see `PendingCallRequest`.
///
/// SwiftUI's `.onContinueUserActivity` handles the warm case, where the app is
/// already running. Both are wired, and placing a call is guarded against
/// running twice, so whichever arrives first wins and the other is a no-op.
final class CallLaunchDelegate: NSObject, UIApplicationDelegate {

    func application(_ application: UIApplication,
                     continue userActivity: NSUserActivity,
                     restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void) -> Bool {
        guard CallIntent.isCallRequest(userActivity) else { return false }
        MainActor.assumeIsolated { PendingCallRequest.record() }
        return true
    }
}
