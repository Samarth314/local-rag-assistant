import Foundation

/// One thing on the daily routine, and whether it has happened today.
///
/// `id` is the vault's own stable key ("vitamin-d3"), which is what every
/// surface addresses. That matters more here than it looks: the daily plan
/// addresses its rows by POSITION, so two quick taps there could tick the
/// wrong row and the whole list has to be frozen during a mutation (see
/// `PlanViewModel.isMutating`). A stable id means this list needs none of
/// that - two taps on two different rows are two independent facts.
struct RoutineItem: Equatable, Hashable, Identifiable {
    let id: String
    /// "Vitamin D3" - what the row says.
    let label: String
    /// "1 tablet", "25 min, Iris Store helmet" - the second line.
    let detail: String
    let done: Bool
    /// "12:41" local, when it was ticked. Nil when it has not been.
    let doneAt: String?
}

/// Today's routine: the four things, the server's date, and the times it will
/// notify about anything still open.
///
/// The DATE comes from the server, never from the phone. The check-off log is
/// written against the vault machine's local day, so a phone in another
/// timezone (or one that has just crossed midnight before the mini has) must
/// render the day the server is actually answering for. `tz` is carried for
/// the same reason - it is what the header can say when the two disagree.
struct DailyRoutine: Equatable {
    let date: String
    let tz: String
    let items: [RoutineItem]
    let reminderTimes: [String]

    static let empty = DailyRoutine(date: "", tz: "", items: [],
                                    reminderTimes: [])

    var doneCount: Int { items.filter(\.done).count }
    var remaining: [RoutineItem] { items.filter { !$0.done } }
    var isEmpty: Bool { items.isEmpty }
    var allDone: Bool { !items.isEmpty && remaining.isEmpty }

    /// The optimistic tick: this list with one row flipped, and nothing else
    /// touched.
    ///
    /// Drawn immediately so a tap lands at thumb speed rather than at tailnet
    /// speed, and thrown away the moment the server answers - with the real
    /// state on success, or with the caller's saved snapshot on failure. The
    /// row's `doneAt` is deliberately cleared rather than invented: the phone
    /// does not know what minute the vault will write, and a guessed time
    /// that then changes is worse than a blank that fills in.
    func setting(id: String, done: Bool) -> DailyRoutine {
        DailyRoutine(
            date: date, tz: tz,
            items: items.map { item in
                item.id == id
                    ? RoutineItem(id: item.id, label: item.label,
                                  detail: item.detail, done: done,
                                  doneAt: done ? item.doneAt : nil)
                    : item
            },
            reminderTimes: reminderTimes)
    }
}

extension DTO {
    /// Named RoutineRow rather than RoutineItem so the domain type stays
    /// unambiguous inside this namespace - the same convention PlanRow uses.
    struct RoutineRow: Decodable {
        let id: String
        let label: String
        let detail: String?
        let done: Bool
        let done_at: String?
    }

    struct Routine: Decodable {
        let date: String
        let tz: String?
        let items: [RoutineRow]
        let reminder_times: [String]?

        var domain: DailyRoutine {
            DailyRoutine(
                date: date,
                tz: tz ?? "",
                items: items.map {
                    RoutineItem(id: $0.id, label: $0.label,
                                detail: $0.detail ?? "", done: $0.done,
                                doneAt: $0.done_at)
                },
                reminderTimes: reminder_times ?? [])
        }
    }
}
