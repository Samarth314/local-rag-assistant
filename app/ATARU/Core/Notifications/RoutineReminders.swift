import Foundation
import UserNotifications

/// The FALLBACK reminder for the daily routine. Not the primary one.
///
/// ## Who normally reminds him
///
/// The mini does. `com.ataru.health-routine` runs at 12:00, 18:00 and 21:00,
/// looks at the vault, and pushes ONE notification naming what is still open.
/// That is the right place for it: the server is the thing that knows the
/// answer, it is awake whether or not the phone is, and it can tell "not done"
/// from "not synced".
///
/// ## Why this exists anyway
///
/// A phone with no APNs registration receives none of that, silently. The token
/// can be missing for perfectly ordinary reasons - notifications denied at
/// first launch and enabled later, a build installed from Xcode whose sandbox
/// token the server has not been handed, a reinstall before the next launch -
/// and every one of them looks identical from the user's side: no reminder,
/// no error, nothing to see. So when there is no registered token, the phone
/// schedules the same three times locally from the list it already has.
///
/// ## Never both
///
/// `reschedule` takes `pushRegistered` and clears everything without
/// scheduling when it is true. Two notifications about the same unchecked box
/// is how a reminder gets switched off, and switched-off reminders are the
/// failure this whole feature exists to avoid. The local ones are also
/// wholesale-replaced on every refresh rather than tracked individually - the
/// same reasoning as `BenefitReminders`, and it means a routine that gets
/// finished at 12:05 has its 18:00 and 21:00 nudges gone by 12:05.
@MainActor
enum RoutineReminders {

    private static let prefix = "ataru.routine."

    /// The APNs `aps.category` the server stamps on the pushed version, and
    /// the `categoryIdentifier` used on the local one, so a tap on either
    /// opens the same place. See `RemotePushService`.
    static let category = "ataru.routine"

    /// Replaces every scheduled local reminder with ones matching the routine
    /// as it stands now.
    ///
    /// - Parameters:
    ///   - routine: today's list, as the server last reported it.
    ///   - pushRegistered: whether the server has an APNs token for this
    ///     phone. True means the server is already handling it and this
    ///     schedules nothing.
    static func reschedule(for routine: DailyRoutine, pushRegistered: Bool,
                           now: Date = Date(),
                           calendar: Calendar = .current) async {
        let center = UNUserNotificationCenter.current()
        let existing = await center.pendingNotificationRequests()
        center.removePendingNotificationRequests(
            withIdentifiers: existing.map(\.identifier).filter {
                $0.hasPrefix(prefix)
            })

        // The server has it. Nothing more to do, and deliberately AFTER the
        // removal above: a phone that registers a token later must have its
        // old local reminders cleared, not left running alongside the pushed
        // ones.
        guard !pushRegistered else { return }
        guard !routine.allDone, !routine.isEmpty else { return }
        guard await hasPermission(center) else { return }

        let body = Self.body(for: routine)
        for time in routine.reminderTimes {
            guard let fire = fireDate(time, on: now, calendar: calendar),
                  fire > now else { continue }
            let content = UNMutableNotificationContent()
            // Generic title, the detail in the body - the same shape the
            // server's push uses, so the two are indistinguishable to him.
            content.title = "Daily routine"
            content.body = body
            content.sound = .default
            content.categoryIdentifier = category
            let request = UNNotificationRequest(
                identifier: "\(prefix)\(routine.date).\(time)",
                content: content,
                trigger: UNCalendarNotificationTrigger(
                    dateMatching: calendar.dateComponents(
                        [.year, .month, .day, .hour, .minute], from: fire),
                    repeats: false))
            try? await center.add(request)
        }
    }

    /// Clears every pending routine reminder. What "everything is done" calls.
    static func clear() async {
        let center = UNUserNotificationCenter.current()
        let existing = await center.pendingNotificationRequests()
        center.removePendingNotificationRequests(
            withIdentifiers: existing.map(\.identifier).filter {
                $0.hasPrefix(prefix)
            })
    }

    /// "Still to do today: White pine, Green juice, Red light" - worded
    /// identically to the server's, so the fallback is not a second voice.
    static func body(for routine: DailyRoutine) -> String {
        "Still to do today: "
            + routine.remaining.map(\.label).joined(separator: ", ")
    }

    /// "18:00" against today's date, in the PHONE's calendar.
    ///
    /// The routine's day boundary is the server's, and this is the one place
    /// that cannot honour it: a local notification fires on this device's
    /// clock and there is nowhere else to put the hour. It is a fallback for a
    /// phone that is with him, so the two agree in every case that matters,
    /// and the pushed version - which is the normal one - has no such gap.
    private static func fireDate(_ time: String, on day: Date,
                                 calendar: Calendar) -> Date? {
        let parts = time.split(separator: ":")
        guard parts.count == 2, let hour = Int(parts[0]),
              let minute = Int(parts[1]) else { return nil }
        return calendar.date(bySettingHour: hour, minute: minute, second: 0,
                             of: day)
    }

    /// Never prompts. The routine card is not a screen anyone opened in order
    /// to answer a permissions dialog, and `RemotePushService` has already
    /// asked once at launch - so this reads the standing answer and stays
    /// quiet if it is no.
    private static func hasPermission(_ center: UNUserNotificationCenter) async -> Bool {
        let settings = await center.notificationSettings()
        return settings.authorizationStatus == .authorized
            || settings.authorizationStatus == .provisional
    }
}
