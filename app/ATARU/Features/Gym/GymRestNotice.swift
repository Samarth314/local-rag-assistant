import Foundation
import UserNotifications

/// "Rest over" - the one notification the Gym screen ever posts.
///
/// ## Why there is a notification at all
///
/// The rest bar is on a screen he is often not looking at: a set is finished,
/// the phone goes in a pocket or onto the bench, and the next thing that
/// should happen is being told the rest is up. A bar that only exists while
/// the app is in the foreground cannot do that, and a phone that has been
/// locked for ninety seconds has nothing else to ask.
///
/// ## What it deliberately does not say
///
/// The exercise, the weight, the reps and the routine are all health-class
/// data (vault CLAUDE.md), and a notification body is drawn on a locked screen
/// where anyone standing nearby reads it. So the text is exactly "Rest over"
/// and nothing else - no exercise name, no set number, no numbers at all.
///
/// ## Permission, asked at the right moment
///
/// Requested the FIRST time a set is completed, not at launch: at that point
/// the prompt is about something that has just happened and the answer means
/// something. Denied is a perfectly good answer - the bar still counts down on
/// screen, and nothing else about the session changes.
///
/// One notification is pending at a time, by construction: it is scheduled on
/// a fixed identifier, so scheduling another replaces it rather than stacking.
/// Skipping the rest, finishing another set, discarding the session and
/// finishing the workout all cancel it.
@MainActor
enum GymRestNotice {

    /// Fixed, so a second schedule replaces the first. A timestamped id would
    /// leave a queue of stale "Rest over" notices from every set of the
    /// session.
    static let identifier = "ataru.gym.rest"

    /// Whether the prompt has already been shown this install. Read from the
    /// centre rather than remembered in a flag - a flag would be wrong after a
    /// reinstall, and the centre knows.
    static func requestPermissionIfNeeded() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound]))
                ?? false
        default:
            // Denied. Not an error and not worth a banner of its own: the rest
            // bar is still on screen and still correct.
            return false
        }
    }

    /// Replaces whatever was pending with one notice at `end`.
    ///
    /// A rest that has already finished schedules nothing - `UNCalendar`/
    /// `UNTimeInterval` triggers refuse a non-positive interval, and a notice
    /// about a rest that is already over is noise.
    static func schedule(at end: Date, now: Date = Date()) async {
        let seconds = end.timeIntervalSince(now)
        guard seconds > 0.5 else {
            cancel()
            return
        }
        guard await requestPermissionIfNeeded() else {
            cancel()
            return
        }
        let content = UNMutableNotificationContent()
        content.title = "Rest over"
        // Deliberately empty. See the note above: the body is the line that
        // would carry a weight or an exercise onto a locked screen.
        content.sound = .default
        content.interruptionLevel = .timeSensitive

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: seconds,
                                                        repeats: false)
        let request = UNNotificationRequest(identifier: identifier,
                                            content: content, trigger: trigger)
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        try? await center.add(request)
    }

    /// Skipped, superseded, discarded or finished. Also clears a notice that
    /// has already been delivered, so a rest he came back to does not leave a
    /// banner sitting in Notification Centre.
    static func cancel() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }
}
