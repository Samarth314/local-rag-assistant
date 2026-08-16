import Foundation

/// One actionable item pulled out of a note.
///
/// The wire shape is FlowList's, deliberately: `POST /api/parse-tasks` with
/// `{ "transcript": "..." }`, answering `{ "tasks": [...] }`, where the server
/// runs the model behind a forced `parse_tasks` tool call and a JSON schema.
/// Same contract, same field names, so one backend can serve both and neither
/// client has a dialect of its own.
struct NoteTask: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String
    var isDone: Bool
    /// Resolved server-side against the current timestamp, so "next Friday" is
    /// already a date by the time it reaches the phone.
    var dueDate: Date?
    /// A specific time of day was said, not just a day.
    var hasTimeTrigger: Bool
    var estimatedMinutes: Int?
    /// One word: Work, Personal, Health, Finance…
    var category: String
    var subtasks: [String]

    init(id: UUID = UUID(), title: String, isDone: Bool = false,
         dueDate: Date? = nil, hasTimeTrigger: Bool = false,
         estimatedMinutes: Int? = nil, category: String = "Personal",
         subtasks: [String] = []) {
        self.id = id
        self.title = title
        self.isDone = isDone
        self.dueDate = dueDate
        self.hasTimeTrigger = hasTimeTrigger
        self.estimatedMinutes = estimatedMinutes
        self.category = category
        self.subtasks = subtasks
    }

    /// A checkbox per point, with nothing the model would have added.
    ///
    /// This is what a note has before — and instead of — a round trip. Every
    /// bullet is tickable the moment the recording stops, offline and on a
    /// backend that has never heard of `/api/parse-tasks`, because the notes
    /// feature does not get to stop working when the Orin is unreachable. The
    /// parsed version replaces these when it arrives; see `NoteStore.adopt`.
    static func fromBullets(_ bullets: [String]) -> [NoteTask] {
        // Condensed, not verbatim. A to-do list of full spoken sentences is
        // the transcript with circles next to it - see NoteDigest.condense.
        var seen = Set<String>()
        return bullets.compactMap { bullet in
            let title = NoteDigest.condense(bullet)
            guard title.split(separator: " ").count >= 2 else { return nil }
            // Two sentences can condense to the same item once the scaffolding
            // is gone: "I need to call the bank" and "remember to call the
            // bank because of the fee" are one task.
            guard seen.insert(title.lowercased()).inserted else { return nil }
            return NoteTask(title: title)
        }
    }

    /// The parsed list, with the ticked state of anything already on the note.
    ///
    /// A parse arrives with fresh UUIDs and `isDone: false` on every row, so
    /// adopting it wholesale cleared boxes the user had ticked - on a note
    /// they had been working through, which is exactly the note most likely to
    /// be parsed while it is open. Rows are matched on the text itself, since
    /// that is the only thing the two lists share: the seeded rows come from
    /// `fromBullets` and the parsed ones from the model.
    ///
    /// Order and content are the server's. Only identity and the checkbox
    /// travel, and only for a row whose text did not change.
    static func merge(parsed: [NoteTask], into existing: [NoteTask]) -> [NoteTask] {
        var byText: [String: NoteTask] = [:]
        for task in existing {
            // First wins: two rows that normalise to the same text are already
            // one item as far as the user is concerned.
            byText[matchKey(task.title)] = byText[matchKey(task.title)] ?? task
        }
        var claimed = Set<UUID>()
        return parsed.map { task in
            guard let previous = byText[matchKey(task.title)],
                  claimed.insert(previous.id).inserted else { return task }
            return NoteTask(id: previous.id,
                            title: task.title,
                            isDone: previous.isDone,
                            dueDate: task.dueDate,
                            hasTimeTrigger: task.hasTimeTrigger,
                            estimatedMinutes: task.estimatedMinutes,
                            category: task.category,
                            subtasks: task.subtasks)
        }
    }

    /// Case and trailing punctuation are not the difference between two tasks.
    private static func matchKey(_ title: String) -> String {
        title.lowercased().trimmingCharacters(
            in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".,;:!?")))
    }
}

// MARK: - Wire

/// `POST /api/parse-tasks` — request and reply, snake_case as FlowList sends it.
enum ParseTasksDTO {

    struct Request: Encodable {
        let transcript: String
    }

    struct Reply: Decodable {
        let tasks: [Task]

        struct Task: Decodable {
            let title: String
            let due_date: String?
            let has_time_trigger: Bool?
            let estimated_duration_minutes: Double?
            let category_tag: String?
            let subtasks: [String]?
        }
    }
}

extension ParseTasksDTO.Reply.Task {
    /// Lenient on everything the schema does not require.
    ///
    /// `title` is the only field worth failing over: the schema marks
    /// `has_time_trigger`, `category_tag` and `subtasks` required too, but a
    /// model is not a validator, and dropping a real task because it came back
    /// without a category would be a worse outcome than a task labelled
    /// "Personal".
    var domain: NoteTask? {
        guard let title = title.nilIfBlank else { return nil }
        return NoteTask(
            title: title,
            dueDate: due_date.flatMap(ParseTasksDTO.date(from:)),
            hasTimeTrigger: has_time_trigger ?? false,
            // Minutes arrive as a JSON number, which may be fractional.
            estimatedMinutes: estimated_duration_minutes.map { Int($0.rounded()) },
            category: category_tag?.nilIfBlank ?? "Personal",
            subtasks: subtasks?.compactMap(\.nilIfBlank) ?? []
        )
    }
}

extension ParseTasksDTO {
    /// ISO 8601, with and without fractional seconds.
    ///
    /// Two formatters because `ISO8601DateFormatter` will not accept both from
    /// one instance, and a model asked for "ISO 8601 datetime" returns either.
    static func date(from string: String) -> Date? {
        guard let trimmed = string.nilIfBlank else { return nil }
        let variants: [ISO8601DateFormatter.Options] = [
            [.withInternetDateTime, .withFractionalSeconds],
            [.withInternetDateTime]
        ]
        for options in variants {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = options
            if let date = formatter.date(from: trimmed) { return date }
        }
        // A bare calendar day is a legitimate answer to "or null if no date".
        let day = DateFormatter()
        day.calendar = Calendar(identifier: .iso8601)
        day.locale = Locale(identifier: "en_US_POSIX")
        day.timeZone = .current
        day.dateFormat = "yyyy-MM-dd"
        return day.date(from: trimmed)
    }
}
