import Foundation

// MARK: - The catalogue

/// One row of openGym's built-in exercise catalogue.
///
/// The state document stores IDS (`"0043"`) and nothing else, so without this
/// the app renders a routine as a column of four-digit numbers. The names, the
/// body parts, the equipment and the animation filenames live in openGym's own
/// generated dataset and arrive from `GET /api/gym/library` - see the vault's
/// records/work/opengym/APP-API.md.
struct GymLibraryEntry: Codable, Equatable, Identifiable, Hashable {
    var id: String
    var name: String
    var bodyPart: String?
    var equipment: String?
    /// A BARE FILENAME, never a URL, and legitimately absent. The full URL is
    /// `media_base` + this string and nothing else - no path joining, no slash
    /// rule. A custom exercise has no animation at all.
    var gif: String?

    enum CodingKeys: String, CodingKey {
        case id, name, gif
        case bodyPart = "body_part"
        case equipment = "equipment"
    }

    /// "waist · body weight", or whichever half exists. Both are nullable in
    /// the dataset and a lone separator reads as a missing field.
    var tagline: String {
        [bodyPart, equipment].compactMap { $0?.isEmpty == false ? $0 : nil }
            .joined(separator: " · ")
    }

    /// What `search` matches on, folded once rather than per keystroke.
    var haystack: String {
        [name, bodyPart ?? "", equipment ?? ""].joined(separator: " ").lowercased()
    }
}

/// The catalogue as the server hands it over.
///
/// `mediaBase` travels with the rows rather than being hardcoded: it is
/// overridable server-side (`ATARU_GYM_MEDIA_BASE`), so a move to a different
/// host or a CDN must not need an app release.
struct GymLibrary: Codable, Equatable {
    var mediaBase: String
    var exercises: [GymLibraryEntry]

    enum CodingKeys: String, CodingKey {
        case mediaBase = "media_base"
        case exercises
    }

    init(mediaBase: String, exercises: [GymLibraryEntry]) {
        self.mediaBase = mediaBase
        self.exercises = exercises
    }

    /// Built on demand and cached by the store, not here: 1324 rows is a
    /// dictionary worth building once and a dictionary worth never building
    /// twice per frame.
    func index() -> [String: GymLibraryEntry] {
        Dictionary(exercises.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// `media_base` + the bare filename. Nil for a row with no animation,
    /// which is a real answer: the placeholder is drawn instead, and a URL is
    /// never built out of a null.
    func gifURL(for entry: GymLibraryEntry) -> URL? {
        guard let gif = entry.gif, !gif.isEmpty else { return nil }
        return URL(string: mediaBase + gif)
    }

    /// Case-folded contains over name, body part and equipment, in the
    /// server's order.
    ///
    /// NOT re-sorted. The server sorts case-folded with the id as the
    /// tiebreak, and a naive Swift sort over a lower-case dataset puts
    /// `"3/4 sit-up"` somewhere else entirely - so a picker that re-sorted
    /// would disagree with every other view of the same list.
    func search(_ query: String, limit: Int = 200) -> [GymLibraryEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return Array(exercises.prefix(limit)) }
        // Every word has to appear somewhere in the row, so "cable row"
        // narrows rather than widening - the behaviour of every search box he
        // already uses.
        let words = needle.split(separator: " ").map(String.init)
        var found: [GymLibraryEntry] = []
        for entry in exercises {
            let hay = entry.haystack
            if words.allSatisfy({ hay.contains($0) }) {
                found.append(entry)
                if found.count >= limit { break }
            }
        }
        return found
    }
}

// MARK: - Custom exercises, as catalogue rows

extension GymState {
    /// The profile's own custom exercises in the catalogue's shape, so one
    /// list can be searched.
    ///
    /// They are merged CLIENT-SIDE and deliberately not cached: the library is
    /// a build artefact held for a day, and a day-old copy of the customs
    /// would hide one Arya added two minutes ago in the browser. They have no
    /// media, so `gif` is nil and the placeholder is drawn.
    var customLibraryEntries: [GymLibraryEntry] {
        (raw["customEx"]?.arrayValue ?? []).compactMap { value in
            guard let object = value.objectValue,
                  let id = object["id"]?.stringValue, !id.isEmpty else { return nil }
            return GymLibraryEntry(
                id: id,
                name: object["n"]?.stringValue ?? id,
                bodyPart: object["bp"]?.stringValue,
                equipment: object["eq"]?.stringValue,
                gif: nil)
        }
    }
}
