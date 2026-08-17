import Foundation
import UserNotifications

/// Nudges before a credit expires.
///
/// ## Why these are local, not pushed
///
/// The Orin knows nothing about which cards someone holds, and there is no
/// reason for it to: the deadline is arithmetic on a date the phone already
/// has. A local notification fires with no server, no network, and no wallet
/// contents leaving the device — which for a list of somebody's credit cards
/// is the difference between a feature and a liability.
///
/// It also means the reminder still arrives on a plane, which is exactly when
/// someone thinks about their airline credit.
@MainActor
enum BenefitReminders {

    /// Days before the period closes. Two nudges, not five: one with enough
    /// time to actually spend it, and one last chance. A credit that nags
    /// weekly gets the notifications turned off, and then none of them work.
    static let leadDays = [14, 3]

    private static let prefix = "ataru.benefit."

    /// Replaces every scheduled reminder with ones matching the wallet as it
    /// stands now.
    ///
    /// Wholesale rather than incremental, because the alternative is tracking
    /// which requests correspond to which benefit across edits, redemptions
    /// and period rollovers - and a stale reminder for a credit already spent
    /// is worse than none, since it sends the user to look for money that is
    /// not there.
    static func reschedule(for statuses: [BenefitStatus], now: Date = Date(),
                           calendar: Calendar = .current) async {
        let center = UNUserNotificationCenter.current()
        let existing = await center.pendingNotificationRequests()
        center.removePendingNotificationRequests(
            withIdentifiers: existing.map(\.identifier).filter { $0.hasPrefix(prefix) })

        guard await hasPermission(center) else { return }

        for status in statuses where !status.isRedeemed && status.benefit.hasCashValue {
            for lead in leadDays {
                guard let fire = fireDate(for: status, leadDays: lead,
                                          calendar: calendar), fire > now else { continue }
                let request = UNNotificationRequest(
                    identifier: "\(prefix)\(status.id).\(lead)",
                    content: content(for: status, leadDays: lead),
                    trigger: UNCalendarNotificationTrigger(
                        dateMatching: calendar.dateComponents(
                            [.year, .month, .day, .hour, .minute], from: fire),
                        repeats: false))
                try? await center.add(request)
            }
        }
    }

    /// Asks only if the answer is not already known. A permission prompt on a
    /// screen the user opened to read a number is a prompt they say no to.
    static func requestPermission() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        case .denied:
            return false
        default:
            return true
        }
    }

    private static func hasPermission(_ center: UNUserNotificationCenter) async -> Bool {
        let settings = await center.notificationSettings()
        return settings.authorizationStatus == .authorized
            || settings.authorizationStatus == .provisional
    }

    /// 10am, `leadDays` before the last usable day.
    ///
    /// Morning rather than the moment the arithmetic says, because a credit
    /// you are told about at 2am is one you have forgotten by breakfast.
    private static func fireDate(for status: BenefitStatus, leadDays: Int,
                                 calendar: Calendar) -> Date? {
        let lastDay = calendar.startOfDay(for: status.period.end.addingTimeInterval(-1))
        guard let day = calendar.date(byAdding: .day, value: -leadDays, to: lastDay) else {
            return nil
        }
        return calendar.date(bySettingHour: 10, minute: 0, second: 0, of: day)
    }

    private static func content(for status: BenefitStatus,
                                leadDays: Int) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        let amount = status.benefit.amount.map {
            "\($0.formatted(.currency(code: "USD").precision(.fractionLength(0))))"
        }
        content.title = amount.map { "\($0) expires in \(leadDays) days" }
            ?? "\(status.benefit.title) expires in \(leadDays) days"
        // The card matters as much as the credit: someone with four cards
        // needs to know which one to reach for.
        content.body = [status.benefit.title, status.card.displayName]
            .joined(separator: " · ")
        content.sound = .default
        return content
    }
}
