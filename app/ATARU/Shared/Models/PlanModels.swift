import Foundation

/// One item on the daily plan - a main thing or a smaller task.
struct PlanItem: Equatable, Hashable {
    let text: String
    let done: Bool
}

/// The day's plan: the three main things plus everything else.
///
/// Mirrors the vault file records/personal/plan/YYYY-MM-DD.md exactly - the
/// same data the 7am call announces and can write by voice, so the tile, the
/// call, and the web page are three views of one list.
struct DailyPlan: Equatable {
    let date: String
    let top3: [PlanItem]
    let also: [PlanItem]

    static func empty(date: String = DailyPlan.todayKey) -> DailyPlan {
        DailyPlan(date: date, top3: [], also: [])
    }

    static var todayKey: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        return formatter.string(from: Date())
    }
}

extension DTO {
    /// Named PlanRow rather than PlanItem so the domain type stays
    /// unambiguous inside this namespace.
    struct PlanRow: Decodable {
        let text: String
        let done: Bool
    }

    struct Plan: Decodable {
        let date: String
        let top3: [PlanRow]
        let also: [PlanRow]

        var domain: DailyPlan {
            DailyPlan(
                date: date,
                top3: top3.map { PlanItem(text: $0.text, done: $0.done) },
                also: also.map { PlanItem(text: $0.text, done: $0.done) })
        }
    }
}
