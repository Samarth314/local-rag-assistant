import Foundation
import UserNotifications

/// The ordinary alert push that arrives alongside the morning VoIP ring.
///
/// ## Why there are two pushes for one call
///
/// A VoIP push is the only thing that can make the phone ring like a phone,
/// and it is also the most fragile push there is: it is delivered at the
/// system's discretion, it is dropped outright when the device is in Low Power
/// Mode or has been asleep long enough, and when it does not arrive there is
/// nothing on the phone to say it ever existed. At seven in the morning the
/// visible failure of that is a phone that simply does not ring.
///
/// So the server now sends both, in the same attempt: the VoIP push that rings,
/// and a plain alert that survives the cases the VoIP push does not. The alert
/// is a fallback for the ring, not a second ring - tapping it opens the app
/// straight into call mode, which is the same thing tapping ATARU in Recents
/// does, and goes through the same `PendingCallRequest`.
///
/// ## What the alert may and may not contain
///
/// Title "ATARU morning call", body "Tap to call in", and nothing else. Both
/// are the server's to write; what matters at this end is that neither may
/// ever carry the brief. This is drawn on a locked screen, and the brief's
/// contents are the vault's - the same rule the Gym rest notice follows, for
/// the same reason.
///
/// ## If both arrive
///
/// Nothing stacks. `CallService.call()` refuses while a call is live, so a tap
/// landing on a ringing VoIP call does nothing to the call and simply brings
/// the app forward onto the call screen that is already there. The banner for
/// it is suppressed in that case too - see `RemotePushService.willPresent`.
enum MorningCallAlert {

    /// `aps.category` on the pushed notification, byte for byte as the mini
    /// stamps it. Registered below so the identifier is one the system knows,
    /// and so there is somewhere to hang an action later.
    ///
    /// The shape deliberately matches `RoutineReminders.category`
    /// ("ataru.routine"): these are the app's two routed categories and they
    /// are read side by side in `RemotePushService.didReceive`.
    static let category = "ataru.morning.call"

    /// A `userInfo` fallback, for a push that carries the intent but not the
    /// category. The live contract does not use it - the category is what the
    /// server stamps - and it costs one dictionary lookup to be tolerant of a
    /// payload that arrives the other way round.
    static let actionKey = "ataru_action"
    static let actionValue = "call"

    /// Whether this notification is asking the app to open into call mode.
    ///
    /// Pure, so the routing decision can be argued with in a test rather than
    /// only inside a notification-centre delegate that no test can reach.
    static func wantsCall(category: String, userInfo: [AnyHashable: Any]) -> Bool {
        if category == Self.category { return true }
        // The server may put the key at the top level or inside `aps`; accept
        // either rather than making the contract depend on which.
        if userInfo[Self.actionKey] as? String == Self.actionValue { return true }
        if let aps = userInfo["aps"] as? [AnyHashable: Any],
           aps[Self.actionKey] as? String == Self.actionValue { return true }
        return false
    }

    /// Registers the category, alongside whatever else already claims one.
    ///
    /// No custom actions yet. The category still has to be declared for the
    /// system to treat it as a known one, and declaring it now is what makes
    /// "Answer" and "Not yet" a one-line change later rather than a change
    /// that also needs a server deploy.
    ///
    /// Additive: it reads the centre's current categories and puts this one
    /// beside them, because `setNotificationCategories` REPLACES the set and a
    /// bare call here would silently unregister anything registered first.
    static func register() async {
        let center = UNUserNotificationCenter.current()
        var categories = await center.notificationCategories()
        categories = categories.filter { $0.identifier != Self.category }
        categories.insert(UNNotificationCategory(identifier: Self.category,
                                                 actions: [],
                                                 intentIdentifiers: [],
                                                 options: []))
        center.setNotificationCategories(categories)
    }
}
