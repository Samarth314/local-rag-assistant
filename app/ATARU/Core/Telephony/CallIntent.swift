import Intents
import Foundation

/// Makes ATARU show up as something you *call* rather than an app you open.
///
/// iOS puts a third-party calling app on a contact card by watching donated
/// interactions: each time a call happens, the app donates an
/// `INStartCallIntent` naming the person, and the system starts offering that
/// app as a way to reach them. There is no API to say "please list me on this
/// contact" — donation is the whole mechanism, which is why a freshly
/// installed app appears nowhere until it has been called at least once.
///
/// ## What this needs to work on a device
///
/// The `com.apple.developer.siri` entitlement, which requires a paid Apple
/// Developer Program membership. It is deliberately *not* switched on by
/// default — see `Signing.xcconfig`. Without it the donation silently no-ops
/// and the contact-card entry never appears; everything else in the app keeps
/// working, and Simulator builds are unaffected either way.
enum CallIntent {

    /// The handle that identifies ATARU to Intents and to the contact card.
    ///
    /// `.unknown` rather than `.phoneNumber` on purpose. A handle typed as a
    /// phone number puts a dialable string on the contact, and "100" — the
    /// Asterisk extension — is a live short code on real networks. Nothing here
    /// should be able to place a cellular call by accident.
    static let handleValue = "ataru"

    static var person: INPerson {
        INPerson(
            personHandle: INPersonHandle(value: handleValue, type: .unknown),
            nameComponents: nameComponents,
            displayName: "ATARU",
            image: nil,
            contactIdentifier: nil,
            customIdentifier: handleValue
        )
    }

    private static var nameComponents: PersonNameComponents {
        var components = PersonNameComponents()
        components.givenName = "ATARU"
        return components
    }

    /// Tells the system a call happened, so ATARU starts appearing as a way to
    /// place one. Call this when a call *ends*, not when it starts: donating on
    /// start would record calls that were cancelled before connecting.
    static func donate(startedAt: Date, endedAt: Date) {
        let intent = INStartCallIntent(
            callRecordFilter: nil,
            callRecordToCallBack: nil,
            audioRoute: .unknown,
            destinationType: .normal,
            contacts: [person],
            callCapability: .audioCall
        )
        intent.suggestedInvocationPhrase = "Call ATARU"

        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .outgoing
        interaction.dateInterval = DateInterval(start: startedAt, end: endedAt)
        interaction.donate { _ in
            // A failed donation costs the contact-card entry and nothing else,
            // and the usual cause is the missing Siri entitlement, which is a
            // build configuration question rather than a runtime one.
        }
    }

    /// Every activity type that can mean "call ATARU".
    ///
    /// `INStartCallIntent` is the modern one and what a Recents tap sends on
    /// iOS 13 and later. `INStartAudioCallIntent` is its deprecated
    /// predecessor, still emitted on some paths, and accepting it costs
    /// nothing. Both must also appear in Info.plist's `NSUserActivityTypes` —
    /// iOS will not deliver an activity type the app has not claimed, and that
    /// silence looks exactly like a handler that is not working.
    static let activityTypes: [String] = [
        NSStringFromClass(INStartCallIntent.self),
        "INStartAudioCallIntent",
    ]

    /// Whether an activity handed to the app is a request to call ATARU.
    ///
    /// No filtering on the intent's contacts, deliberately. There is exactly
    /// one thing this app can call, so any call request is a request to call
    /// it. The previous contact check could only ever *reject* a request the
    /// user had explicitly made — the handle in a redial comes back through
    /// several layers of the system and does not reliably survive as the string
    /// that was sent. If ATARU ever gains a second callee, the decision returns
    /// here.
    static func isCallRequest(_ activity: NSUserActivity) -> Bool {
        activityTypes.contains(activity.activityType)
    }
}
