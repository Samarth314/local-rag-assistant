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
        self.title = Note.derivedTitle(from: digest, transcript: transcript)
    }

    /// The first handful of words, which is what people recognise a note by.
    /// Taken from the first point rather than the summary: the summary may
    /// start anywhere in the note, and a list you scan wants the opening words.
    static func derivedTitle(from digest: NoteDigest, transcript: String) -> String {
        let source = digest.bullets.first
            ?? digest.summary.nilIfBlank
            ?? transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = source.split(separator: " ")
        guard !words.isEmpty else { return "Untitled note" }
        let head = words.prefix(7).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " .,;:"))
        return words.count > 7 ? head + "…" : head
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
