import Foundation

/// Formats telemetry values into short, unit-bearing strings.
enum MetricFormatter {

    /// Drops trailing zeros: 1.40 -> "1.4", 70.0 -> "70".
    static func trim(_ value: Double) -> String {
        if value == value.rounded() && abs(value) < 1_000_000 {
            return String(Int(value.rounded()))
        }
        return String(format: "%.1f", value)
    }

    static func string(value: Double, unit: String) -> String {
        switch unit {
        case "%": return "\(Int(value.rounded()))%"
        case "°C": return "\(Int(value.rounded()))°"
        default:
            let trimmed = trim(value)
            return unit.isEmpty ? trimmed : "\(trimmed)\(unit.hasPrefix(" ") ? "" : " ")\(unit)"
        }
    }

    /// Binary byte sizes: 1.7 GB, 86.6 KB.
    static func bytes(_ value: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        return formatter.string(fromByteCount: value)
    }

    /// Uptime rendered the way the dashboard does: "3.5d", "6h", "42m".
    static func uptime(_ interval: TimeInterval) -> String {
        let days = interval / 86_400
        if days >= 1 { return String(format: "%.1fd", days) }
        let hours = interval / 3_600
        if hours >= 1 { return "\(Int(hours))h" }
        return "\(max(1, Int(interval / 60)))m"
    }

    /// Playback position, e.g. 1:04.
    static func playback(_ interval: TimeInterval) -> String {
        guard interval.isFinite, interval >= 0 else { return "0:00" }
        let total = Int(interval.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

enum DateFormatting {
    private static let medium: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none; return f
    }()
    private static let clock: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()
    private static let seconds: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "ss"; return f
    }()
    private static let weekday: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEEE, MMMM d"; return f
    }()
    private static let iso: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f
    }()

    static func medium(_ date: Date) -> String { medium.string(from: date) }
    static func clock(_ date: Date) -> String { clock.string(from: date) }
    static func seconds(_ date: Date) -> String { seconds.string(from: date) }
    static func weekdayLine(_ date: Date) -> String { weekday.string(from: date).uppercased() }
    static func isoDay(_ date: Date) -> String { iso.string(from: date) }

    /// Greeting used on Home.
    static func greeting(for date: Date, calendar: Calendar = .current) -> String {
        switch calendar.component(.hour, from: date) {
        case 0..<5: return "Still up"
        case 5..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        case 17..<22: return "Good evening"
        default: return "Good night"
        }
    }
}

enum RelativeTime {
    private static let formatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    static func string(for date: Date, now: Date = Date()) -> String {
        formatter.localizedString(for: date, relativeTo: now)
    }

    /// Compact form used in dense headers: "16.1 h ago", "4 m ago".
    static func compact(for date: Date, now: Date = Date()) -> String {
        let delta = now.timeIntervalSince(date)
        if delta < 60 { return "just now" }
        if delta < 3_600 { return "\(Int(delta / 60)) m ago" }
        if delta < 86_400 { return String(format: "%.1f h ago", delta / 3_600) }
        return "\(Int(delta / 86_400)) d ago"
    }
}
