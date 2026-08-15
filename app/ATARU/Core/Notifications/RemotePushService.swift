import Combine
import OSLog
import UIKit
import UserNotifications

/// Logging for the notification path, which like the call-intent path cannot
/// be observed any other way: it runs at launch, and its whole job is to hand
/// a token to a server. A notification that never arrives looks identical
/// whether the token was never issued, never uploaded, or uploaded to the
/// wrong backend.
///
///     log stream --device --predicate 'subsystem == "com.ataru.client"'
///
let pushLog = Logger(subsystem: "com.ataru.client", category: "push")

/// Ordinary notifications - the ones that used to come from ntfy.
///
/// ## Not the same thing as the morning ring
///
/// ATARU has two push paths and they share nothing but the `aps-environment`
/// entitlement. `VoIPPushService` receives PushKit VoIP pushes, wakes the app
/// in the background and reports a call to CallKit; it is bound by the rule
/// that a VoIP push which does not report a call gets the app terminated. This
/// is the plain APNs path: a banner, a sound, no wake-up contract, and nothing
/// that can cost the app its VoIP entitlement. They are kept deliberately
/// separate for that reason - do not merge them.
///
/// What IS shared, on purpose, is `VoIPPushService.environment`. Both tokens
/// go to the same APNs key, and an Xcode-installed build gets sandbox tokens
/// while TestFlight and the App Store get production ones. Sending to the
/// wrong host fails as `BadDeviceToken` and the notification simply never
/// arrives, so the client tells the server which kind of build it is rather
/// than leaving it to guess. Reading that value is the only contact between
/// the two services.
///
/// ## Why registration is unconditional and repeated
///
/// `didRegisterForRemoteNotificationsWithDeviceToken` fires on every launch,
/// and the token can rotate after a reinstall, a restore, or at Apple's
/// discretion. A stale token fails silently - nothing arrives, and nothing
/// anywhere says why - so every token this app is handed is uploaded, every
/// launch, and the endpoint is idempotent. This is the same reasoning
/// `registerVoIPToken` is documented with.
///
/// Registration also happens whether or not the user allowed alerts. Denying
/// the prompt costs the banner, not the token, and a registered token means
/// turning notifications on later in Settings starts working immediately
/// rather than after the next launch.
@MainActor
final class RemotePushService: NSObject, ObservableObject {
    static let shared = RemotePushService()

    /// The most recent APNs token, hex-encoded as the server expects.
    @Published private(set) var token: String?
    @Published private(set) var authorization: UNAuthorizationStatus = .notDetermined
    /// Last upload error. Surfaced nowhere yet; kept so Settings can grow a row
    /// like the VoIP one, where a phone that cannot be notified says so instead
    /// of just staying quiet.
    @Published private(set) var registrationError: String?

    private var service: ATARUService?

    private override init() { super.init() }

    /// Ask, then register. Call once per launch.
    ///
    /// Nothing here blocks the UI: the caller does not await it, the
    /// authorization request is the system's own async dialog, and a failure at
    /// any step is logged and dropped. The app works exactly as before with
    /// notifications denied.
    func start() {
        UNUserNotificationCenter.current().delegate = self
        Task { await requestThenRegister() }
    }

    /// Point at the current backend, and re-upload. Called whenever Demo ⇄ Live
    /// flips, because a token registered with Demo reaches nothing.
    func update(service: ATARUService) {
        self.service = service
        if let token { upload(token) }
    }

    private func requestThenRegister() async {
        let center = UNUserNotificationCenter.current()
        do {
            // Shows the system prompt the first time and only the first time;
            // afterwards it returns the standing answer without a dialog, which
            // is why this needs no "have we asked yet" flag of its own.
            let granted = try await center.requestAuthorization(
                options: [.alert, .sound, .badge])
            pushLog.notice("notification authorization granted: \(granted, privacy: .public)")
        } catch {
            pushLog.error("notification authorization failed: \(error.localizedDescription, privacy: .public)")
        }
        authorization = await center.notificationSettings().authorizationStatus

        // Unconditional - see the note above about denied alerts still being
        // worth a token.
        UIApplication.shared.registerForRemoteNotifications()
    }

    // MARK: - From the app delegate

    func didRegister(deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        // Logged by length, never by value: a device token is a routing
        // capability for this phone and does not belong in a log.
        pushLog.notice("APNs token received (\(hex.count, privacy: .public) hex chars)")
        token = hex
        upload(hex)
    }

    func didFailToRegister(_ error: Error) {
        registrationError = error.localizedDescription
        pushLog.error("APNs registration failed: \(error.localizedDescription, privacy: .public)")
    }

    // MARK: - Upload

    private func upload(_ token: String) {
        guard let service else {
            // Ordinary at launch: the token can arrive before AppState has
            // resolved a service. `update(service:)` re-uploads.
            pushLog.notice("token held - no backend configured yet")
            return
        }
        Task { @MainActor in
            do {
                try await service.registerPushToken(
                    token, environment: VoIPPushService.environment)
                registrationError = nil
                pushLog.notice("APNs token registered with the backend")
            } catch {
                // Silent by design. There is nothing the user can do about it
                // and nothing in the app depends on it having worked.
                registrationError = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                pushLog.error("push registration failed: \(self.registrationError ?? "", privacy: .public)")
            }
        }
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension RemotePushService: UNUserNotificationCenterDelegate {

    /// Show the banner even with ATARU open.
    ///
    /// The default is to suppress it, on the assumption that an app on screen
    /// has already told you whatever the notification would have. That is
    /// wrong here: these are vault and system events - a renewal, a lab result
    /// landing, a machine going down - and none of them are on the screen you
    /// happen to be reading.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler:
            @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
