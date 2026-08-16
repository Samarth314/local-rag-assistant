import Foundation

/// One dictated note.
struct Note: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String
    var createdAt: Date
    /// Exactly what was said, kept verbatim. The digest is derived and can be
    /// rebuilt; this cannot, so it is the thing actually being stored.
    var transcript: String
    var digest: NoteDigest
    var duration: TimeInterval
    /// Who said what, when more than one person did. Nil is the normal case
    /// and means "one speaker, or no way to tell" - see SpeakerSplit, which
    /// declines rather than guesses.
    var turns: [SpeakerSplit.Turn]?
    /// The tickable items. Seeded from the digest's own points so a note is
    /// actionable the instant it is saved, then replaced by the parsed version
    /// if the backend has the route. See NoteStore.adopt.
    var tasks: [NoteTask]
    /// True once the server's parse has been applied, so a note is not asked
    /// to parse twice.
    var isParsed: Bool

    /// True when the note is a conversation rather than a monologue.
    var hasMultipleSpeakers: Bool {
        guard let turns else { return false }
        return Set(turns.map(\.speaker)).count > 1
    }

    init(id: UUID = UUID(), createdAt: Date = Date(),
         transcript: String, duration: TimeInterval = 0,
         turns: [SpeakerSplit.Turn]? = nil) {
        let digest = NoteDigest.make(from: transcript)
        self.id = id
        self.createdAt = createdAt
        self.transcript = transcript
        self.digest = digest
        self.duration = duration
        self.turns = turns
        self.tasks = NoteTask.fromBullets(digest.bullets)
        self.isParsed = false
        self.title = Note.derivedTitle(from: digest, transcript: transcript)
    }

    /// The first handful of words, which is what people recognise a note by.
    /// Taken from the first point rather than the summary: the summary may
    /// start anywhere in the note, and a list you scan wants the opening words.
    static func derivedTitle(from digest: NoteDigest, transcript: String) -> String {
        let source = digest.bullets.first.map(NoteDigest.condense)
            ?? digest.summary.nilIfBlank
            ?? transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = source.split(separator: " ")
        guard !words.isEmpty else { return "Untitled note" }
        let head = words.prefix(7).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " .,;:"))
        return words.count > 7 ? head + "…" : head
    }
}

extension Note {
    /// Notes written before tasks existed decode with none, rather than
    /// failing and taking the whole file with them - `notes.json` is a single
    /// document, so one undecodable note loses every note the user has.
    enum CodingKeys: String, CodingKey {
        case id, title, createdAt, transcript, digest, duration, turns, tasks, isParsed
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        transcript = try container.decode(String.self, forKey: .transcript)
        digest = try container.decode(NoteDigest.self, forKey: .digest)
        duration = try container.decodeIfPresent(TimeInterval.self, forKey: .duration) ?? 0
        turns = try container.decodeIfPresent([SpeakerSplit.Turn].self, forKey: .turns)
        tasks = try container.decodeIfPresent([NoteTask].self, forKey: .tasks)
            ?? NoteTask.fromBullets(digest.bullets)
        isParsed = try container.decodeIfPresent(Bool.self, forKey: .isParsed) ?? false
    }
}

extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Every note, on disk.
///
/// ## Where they live
///
/// Application Support, not Caches, and not `UserDefaults`. These are the only
/// thing in the app the user *authored*: a server response can always be
/// fetched again and this cannot, so it is the one kind of data here that must
/// survive a low-storage purge and ride along in a device backup. That is the
/// documented contract of Application Support and the opposite of Caches,
/// which `HomeCache` uses precisely because a lost cache costs nothing.
///
/// Nothing is uploaded. A note never becomes a question, never reaches the
/// assistant, and never leaves the phone — see `NoteDigest` for why the
/// summary is built locally.
@MainActor
final class NoteStore: ObservableObject {
    @Published private(set) var notes: [Note] = []

    private let fileURL: URL?

    init(fileURL: URL? = NoteStore.defaultFileURL()) {
        self.fileURL = fileURL
        load()
    }

    nonisolated static func defaultFileURL() -> URL? {
        let manager = FileManager.default
        guard let directory = manager.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask).first else { return nil }
        // Application Support is not guaranteed to exist on a fresh install,
        // unlike Caches and Documents. Writing into a missing directory fails
        // silently at exactly the moment a first note is taken.
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "notes.json")
    }

    func add(_ note: Note) {
        notes.insert(note, at: 0)
        save()
    }

    func delete(_ note: Note) {
        notes.removeAll { $0.id == note.id }
        save()
    }

    /// Replaces a note's seeded items with the ones the server parsed.
    ///
    /// Only ever called with a non-empty list. An empty parse means the model
    /// found nothing actionable, and wiping the user's checkboxes on that
    /// basis is worse than leaving the bullets they can already tick.
    func adopt(_ tasks: [NoteTask], for note: Note) {
        guard let index = notes.firstIndex(where: { $0.id == note.id }),
              !tasks.isEmpty else { return }
        notes[index].tasks = tasks
        notes[index].isParsed = true
        save()
    }

    /// Marks a parse attempt finished without changing anything, so a note
    /// whose server found nothing is not asked again on every appearance.
    func markParsed(_ note: Note) {
        guard let index = notes.firstIndex(where: { $0.id == note.id }) else { return }
        notes[index].isParsed = true
        save()
    }

    func setTask(_ task: NoteTask, done: Bool, in note: Note) {
        guard let noteIndex = notes.firstIndex(where: { $0.id == note.id }),
              let taskIndex = notes[noteIndex].tasks.firstIndex(where: { $0.id == task.id })
        else { return }
        notes[noteIndex].tasks[taskIndex].isDone = done
        save()
    }

    func note(id: UUID) -> Note? { notes.first { $0.id == id } }

    func rename(_ note: Note, to title: String) {
        guard let index = notes.firstIndex(where: { $0.id == note.id }),
              let trimmed = title.nilIfBlank else { return }
        notes[index].title = trimmed
        save()
    }

    private func load() {
        guard let fileURL, let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder().decode([Note].self, from: data)
        else { return }
        notes = stored.sorted { $0.createdAt > $1.createdAt }
    }

    private func save() {
        guard let fileURL, let data = try? JSONEncoder().encode(notes) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
