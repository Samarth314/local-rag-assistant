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
/// Nothing is uploaded unless the user asks for it. A note never becomes a
/// question and never reaches the assistant on its own - see `NoteDigest` for
/// why the summary is built locally. The single exception is deliberate and
/// manual: "Find tasks" on the note detail sends that one transcript to the
/// configured ATARU server, and the button says so. Nothing on this path runs
/// without a tap.
@MainActor
final class NoteStore: ObservableObject {
    @Published private(set) var notes: [Note] = []
    /// What went wrong with the file, if anything. Nil is the normal case.
    ///
    /// Notes are the only thing in the app the user authored, so a read or
    /// write that failed has to be visible: an unreadable file rendering as
    /// "No notes yet" tells someone their notes are gone when they are not,
    /// and a failed write behind a "Saved" toast loses the note silently.
    @Published private(set) var failure: String?

    private let fileURL: URL?
    private let fileManager = FileManager.default
    /// Set when `load` found a file it could not read. The next write moves it
    /// aside rather than overwriting it - whatever is in there is the only
    /// copy, and a decoder that cannot read it today is not proof it is worth
    /// destroying.
    private var isUnreadable = false

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

    /// Takes on the server's parse, keeping every box the user already ticked.
    ///
    /// Only ever called with a non-empty list. An empty parse means the model
    /// found nothing actionable, and wiping the user's checkboxes on that
    /// basis is worse than leaving the bullets they can already tick.
    ///
    /// The straight assignment this replaced also threw away identity: every
    /// parsed row arrived with a fresh UUID and `isDone: false`, so a note
    /// worked through before the parse came back came out of it with every box
    /// clear and no way to tell that had happened. Rows whose text is
    /// unchanged keep their id and their ticked state; see `NoteTask.merge`.
    func adopt(_ tasks: [NoteTask], for note: Note) {
        guard let index = notes.firstIndex(where: { $0.id == note.id }),
              !tasks.isEmpty else { return }
        notes[index].tasks = NoteTask.merge(parsed: tasks, into: notes[index].tasks)
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
        guard let fileURL else {
            failure = "There is nowhere on this phone to keep notes."
            return
        }
        // No file is the first launch, and the empty state is the truth.
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        guard let data = try? Data(contentsOf: fileURL) else {
            isUnreadable = true
            failure = "Couldn't open your notes file. Nothing has been changed."
            return
        }
        guard let stored = try? JSONDecoder().decode([Note].self, from: data) else {
            isUnreadable = true
            failure = "Your notes file couldn't be read. It is still on the phone and nothing has been overwritten."
            return
        }
        notes = stored.sorted { $0.createdAt > $1.createdAt }
    }

    private func save() {
        guard let fileURL else {
            failure = "There is nowhere on this phone to keep notes."
            return
        }
        // A file that would not decode is moved aside, never written over: it
        // is the only copy of whatever it holds.
        if isUnreadable {
            let stamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            let aside = fileURL.deletingLastPathComponent()
                .appending(path: "notes-unreadable-\(stamp).json")
            guard (try? fileManager.moveItem(at: fileURL, to: aside)) != nil else {
                failure = "Couldn't save - the existing notes file is unreadable and could not be moved aside."
                return
            }
            isUnreadable = false
        }
        guard let data = try? JSONEncoder().encode(notes) else {
            failure = "Couldn't save this note."
            return
        }
        do {
            try data.write(to: fileURL, options: .atomic)
            failure = nil
        } catch {
            failure = "Couldn't save to the phone. The note is still on screen."
        }
    }
}
