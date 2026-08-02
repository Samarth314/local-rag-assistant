import Intents
import OSLog
import SwiftUI
import UIKit

/// Logging for the call-intent path.
///
/// This path cannot be observed any other way: it runs at launch, before any
/// UI, driven entirely by what iOS chooses to hand over. When a Recents tap
/// "does nothing", the only question that matters is whether an activity
/// arrived at all — and without this there is no way to tell a rejected
/// activity from one that was never delivered.
///
///     log stream --device --predicate 'subsystem == "com.ataru.client"'
///
let callLog = Logger(subsystem: "com.ataru.client", category: "call-intent")

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
        // Logged before the check, so a delivered-but-rejected activity is
        // distinguishable from one that never arrived.
        callLog.notice("delegate received activity: \(userActivity.activityType, privacy: .public)")
        guard CallIntent.isCallRequest(userActivity) else {
            callLog.notice("not a call request — ignored")
            return false
        }
        MainActor.assumeIsolated { PendingCallRequest.record() }
        callLog.notice("recorded pending call request")
        return true
    }

    /// Logs whether the app was launched with an activity at all. A Recents tap
    /// that opens the app and does nothing looks identical whether iOS sent an
    /// activity we rejected or sent nothing; this separates the two.
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions:
                        [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let activityType = (launchOptions?[.userActivityDictionary] as? [String: Any])
            .flatMap { $0["UIApplicationLaunchOptionsUserActivityKey"] as? NSUserActivity }?
            .activityType
        callLog.notice("launched with activity: \(activityType ?? "none", privacy: .public)")
        // A VoIP push can cold launch the app in the background, and iOS
        // requires the PKPushRegistry delegate to exist and report a call
        // before this method returns to the run loop. RootView's init also
        // touches CallStack, but a background launch may never evaluate a
        // scene body - the app delegate is the only place guaranteed to run.
        MainActor.assumeIsolated { _ = CallStack.shared }
        callLog.notice("call stack initialized at launch")
        return true
    }
}
