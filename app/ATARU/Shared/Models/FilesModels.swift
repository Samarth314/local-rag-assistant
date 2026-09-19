import Foundation

// MARK: - Time

/// The files index speaks ISO-8601 strings, not Unix timestamps.
///
/// Everything else in this API sends numbers (see `DTO`), so this is the one
/// place that parses dates from text - and it accepts the three shapes a
/// Python backend actually emits: with fractional seconds, without, and a
/// naive local stamp carrying no zone at all. A stamp that will not parse
/// becomes nil rather than 1 January 1970: "unknown" is a date the UI can
/// render honestly, and an epoch is not.
enum ISO8601Time {

    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let internet: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// `2026-09-19T08:14:02` - no zone. Read as UTC, which is what the
    /// server's own `datetime.utcnow().isoformat()` means by it.
    private static let naive: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter
    }()

    private static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func parse(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        if let date = fractional.date(from: value) { return date }
        if let date = internet.date(from: value) { return date }
        if let date = naive.date(from: String(value.prefix(19))) { return date }
        return day.date(from: value)
    }

    static func string(_ date: Date?) -> String? {
        guard let date else { return nil }
        return internet.string(from: date)
    }

    /// "YYYY-MM-DD", which is what `since` and `until` are.
    static func dayString(_ date: Date) -> String { day.string(from: date) }
}

// MARK: - Kinds

/// What sort of file this is, as the index classifies it.
///
/// Deliberately coarse. The index sees several hundred extensions; a browser
/// filter with several hundred chips is not a filter. An extension the server
/// has not classified arrives as `.other` rather than failing the page.
enum FileKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case pdf, doc, slides, sheet, text, image, video, audio, other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pdf: return "PDF"
        case .doc: return "Docs"
        case .slides: return "Slides"
        case .sheet: return "Sheets"
        case .text: return "Text"
        case .image: return "Images"
        case .video: return "Video"
        case .audio: return "Audio"
        case .other: return "Other"
        }
    }

    /// Singular, for one row rather than a filter chip.
    var rowTitle: String {
        switch self {
        case .doc: return "Document"
        case .slides: return "Slide deck"
        case .sheet: return "Spreadsheet"
        case .image: return "Image"
        case .video: return "Video"
        case .audio: return "Audio"
        default: return title
        }
    }

    var symbol: String {
        switch self {
        case .pdf: return "doc.richtext"
        case .doc: return "doc.text"
        case .slides: return "rectangle.on.rectangle"
        case .sheet: return "tablecells"
        case .text: return "text.alignleft"
        case .image: return "photo"
        case .video: return "film"
        case .audio: return "waveform"
        case .other: return "doc"
        }
    }

    init(serverValue: String) {
        self = FileKind(rawValue: serverValue.lowercased()) ?? .other
    }
}

/// Whether the bytes are on the host the app is talking to.
///
/// `nas-away` is the tiering system's other half - the folder is on the NAS
/// and only an `AWAY.md` placeholder is on disk (see the vault's tier.py). The
/// distinction is load-bearing in the viewer: an away file has no content to
/// fetch, and the honest answer is to say so rather than to spin.
enum FileLocation: String, Codable, Sendable {
    case local
    case nasAway = "nas-away"

    var isAway: Bool { self == .nasAway }

    var badge: String { isAway ? "NAS" : "" }
    var symbol: String { isAway ? "externaldrive.badge.icloud" : "internaldrive" }

    /// An unrecognised location is read as `local`: the badge is a claim
    /// ("this is not on the host"), and a claim should not be made on the
    /// strength of a word this build does not know. A content fetch that then
    /// 404s reports honestly on its own.
    init(serverValue: String) {
        self = FileLocation(rawValue: serverValue.lowercased()) ?? .local
    }
}

enum FileSort: String, CaseIterable, Identifiable, Sendable {
    case relevance
    case mtimeDesc = "mtime_desc"
    case mtimeAsc = "mtime_asc"
    case name
    case sizeDesc = "size_desc"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .relevance: return "Best match"
        case .mtimeDesc: return "Recent"
        case .mtimeAsc: return "Oldest"
        case .name: return "Name"
        case .sizeDesc: return "Largest"
        }
    }

    /// Relevance means nothing without a query, so the menu hides it while
    /// browsing rather than offering an order the server cannot produce.
    static func options(searching: Bool) -> [FileSort] {
        searching ? allCases : allCases.filter { $0 != .relevance }
    }
}

// MARK: - One file

/// One row of the files index.
///
/// `id` is opaque and server-assigned. `path` is carried because the browser
/// shows where a file lives, and it is NEVER sent back: every route addresses
/// a file by id, exactly as the vault library does. See PRIVACY.md.
struct FileHit: Identifiable, Equatable, Hashable, Codable, Sendable {
    let id: String
    let path: String
    let name: String
    let title: String
    let ext: String
    let kind: FileKind
    let pod: String?
    let umbrella: String?
    let project: String?
    let mtime: Date?
    let size: Int64?
    let location: FileLocation
    /// Present only on a search; a browse has nothing to highlight.
    let snippet: String?
    /// Likewise: relevance only exists relative to a query.
    let score: Double?
    let hasText: Bool

    init(id: String, path: String, name: String, title: String? = nil,
         ext: String? = nil, kind: FileKind, pod: String? = nil,
         umbrella: String? = nil, project: String? = nil, mtime: Date? = nil,
         size: Int64? = nil, location: FileLocation = .local,
         snippet: String? = nil, score: Double? = nil, hasText: Bool = false) {
        self.id = id
        self.path = path
        self.name = name
        self.title = title?.isEmpty == false ? title! : name
        self.ext = (ext ?? Self.extension(of: name)).lowercased()
        self.kind = kind
        self.pod = pod
        self.umbrella = umbrella
        self.project = project
        self.mtime = mtime
        self.size = size
        self.location = location
        self.snippet = snippet
        self.score = score
        self.hasText = hasText
    }

    static func `extension`(of name: String) -> String {
        let suffix = (name as NSString).pathExtension
        return suffix.lowercased()
    }

    /// What the row shows under the name when there is no snippet: where the
    /// file lives, in the words the browser filters by.
    var placeLine: String {
        let parts = [umbrella, project ?? pod].compactMap { value -> String? in
            guard let value, !value.isEmpty else { return nil }
            return value
        }
        if parts.isEmpty {
            let parent = (path as NSString).deletingLastPathComponent
            let last = (parent as NSString).lastPathComponent
            return last.isEmpty ? "Files" : last
        }
        return parts.joined(separator: " · ")
    }

    enum CodingKeys: String, CodingKey {
        case id, path, name, title, ext, kind, pod, umbrella, project
        case mtime, size, location, snippet, score
        case hasText = "has_text"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        path = try container.decodeIfPresent(String.self, forKey: .path) ?? ""
        let decodedName = try container.decodeIfPresent(String.self, forKey: .name)
            ?? (path as NSString).lastPathComponent
        name = decodedName
        let decodedTitle = try container.decodeIfPresent(String.self, forKey: .title)
        title = (decodedTitle?.isEmpty == false) ? decodedTitle! : decodedName
        let decodedExt = try container.decodeIfPresent(String.self, forKey: .ext)
        ext = (decodedExt?.isEmpty == false ? decodedExt! : Self.extension(of: decodedName))
            .lowercased()
        kind = FileKind(serverValue:
            try container.decodeIfPresent(String.self, forKey: .kind) ?? "")
        pod = try container.decodeIfPresent(String.self, forKey: .pod)
        umbrella = try container.decodeIfPresent(String.self, forKey: .umbrella)
        project = try container.decodeIfPresent(String.self, forKey: .project)
        mtime = ISO8601Time.parse(
            try container.decodeIfPresent(String.self, forKey: .mtime))
        size = try container.decodeIfPresent(Int64.self, forKey: .size)
        location = FileLocation(serverValue:
            try container.decodeIfPresent(String.self, forKey: .location) ?? "")
        let decodedSnippet = try container.decodeIfPresent(String.self, forKey: .snippet)
        snippet = decodedSnippet?.isEmpty == true ? nil : decodedSnippet
        score = try container.decodeIfPresent(Double.self, forKey: .score)
        hasText = try container.decodeIfPresent(Bool.self, forKey: .hasText) ?? false
    }

    /// Written by hand rather than synthesised because `mtime` has to go back
    /// out as the ISO string it came in as. The synthesised encoder would
    /// write a `Double`, which this file's own decoder cannot read - and the
    /// listing is round-tripped through `TileCache` on every open.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(path, forKey: .path)
        try container.encode(name, forKey: .name)
        try container.encode(title, forKey: .title)
        try container.encode(ext, forKey: .ext)
        try container.encode(kind.rawValue, forKey: .kind)
        try container.encodeIfPresent(pod, forKey: .pod)
        try container.encodeIfPresent(umbrella, forKey: .umbrella)
        try container.encodeIfPresent(project, forKey: .project)
        try container.encodeIfPresent(ISO8601Time.string(mtime), forKey: .mtime)
        try container.encodeIfPresent(size, forKey: .size)
        try container.encode(location.rawValue, forKey: .location)
        try container.encodeIfPresent(snippet, forKey: .snippet)
        try container.encodeIfPresent(score, forKey: .score)
        try container.encode(hasText, forKey: .hasText)
    }
}

// MARK: - Facets

/// Counts per value, as the server computed them over the WHOLE match set -
/// not over the page on screen.
///
/// This is why the rails are built from facets rather than from the rows:
/// counting the loaded page would relabel every chip on "load more", and the
/// numbers would be wrong until the last page arrived.
struct FileFacets: Equatable, Codable, Sendable {
    var pod: [String: Int] = [:]
    var umbrella: [String: Int] = [:]
    var kind: [String: Int] = [:]
    var year: [String: Int] = [:]

    static let empty = FileFacets()

    var isEmpty: Bool {
        pod.isEmpty && umbrella.isEmpty && kind.isEmpty && year.isEmpty
    }

    init(pod: [String: Int] = [:], umbrella: [String: Int] = [:],
         kind: [String: Int] = [:], year: [String: Int] = [:]) {
        self.pod = pod
        self.umbrella = umbrella
        self.kind = kind
        self.year = year
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pod = try container.decodeIfPresent([String: Int].self, forKey: .pod) ?? [:]
        umbrella = try container.decodeIfPresent([String: Int].self, forKey: .umbrella) ?? [:]
        kind = try container.decodeIfPresent([String: Int].self, forKey: .kind) ?? [:]
        year = try container.decodeIfPresent([String: Int].self, forKey: .year) ?? [:]
    }

    /// Umbrella names in the order the browser shows them: Arya's own reach
    /// order first (the same order `~/Projects/CLAUDE.md` lists them in), then
    /// anything the server knows about that this build does not, alphabetically.
    ///
    /// A hardcoded order that SILENTLY DROPPED unknown names would be a
    /// browser that cannot see a folder added next week, so the tail is
    /// appended rather than filtered.
    static let umbrellaOrder = ["Robolabs", "Career", "Graduate School", "Research",
                                "Book", "Robotics Startup", "Quantum", "ATARU",
                                "Experiments"]

    var orderedUmbrellas: [(name: String, count: Int)] {
        let known = Self.umbrellaOrder.compactMap { name -> (String, Int)? in
            guard let count = umbrella[name], count > 0 else { return nil }
            return (name, count)
        }
        let rest = umbrella.keys
            .filter { !Self.umbrellaOrder.contains($0) && (umbrella[$0] ?? 0) > 0 }
            .sorted()
            .map { ($0, umbrella[$0] ?? 0) }
        return (known + rest).map { (name: $0.0, count: $0.1) }
    }

    var orderedPods: [(name: String, count: Int)] {
        pod.filter { $0.value > 0 }.sorted { lhs, rhs in
            lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value
        }.map { (name: $0.key, count: $0.value) }
    }

    /// In `FileKind`'s own declaration order, so the chips do not reshuffle
    /// as counts move.
    var orderedKinds: [(kind: FileKind, count: Int)] {
        FileKind.allCases.compactMap { value in
            guard let count = kind[value.rawValue], count > 0 else { return nil }
            return (kind: value, count: count)
        }
    }

    /// Newest year first.
    var orderedYears: [(year: Int, count: Int)] {
        year.compactMap { key, count -> (Int, Int)? in
            guard let value = Int(key), count > 0 else { return nil }
            return (value, count)
        }
        .sorted { $0.0 > $1.0 }
        .map { (year: $0.0, count: $0.1) }
    }
}

// MARK: - A page of results

struct FileSearchResult: Equatable, Codable, Sendable {
    let total: Int
    let page: Int
    let pageSize: Int
    let hits: [FileHit]
    let facets: FileFacets

    static let empty = FileSearchResult(total: 0, page: 1, pageSize: 0,
                                        hits: [], facets: .empty)

    /// Whether another page exists. Derived from what has been LOADED so far,
    /// which the caller passes in - `hits.count` is this page only.
    func hasMore(loaded: Int) -> Bool { loaded < total }

    enum CodingKeys: String, CodingKey {
        case total, page, hits, facets
        case pageSize = "page_size"
    }

    init(total: Int, page: Int, pageSize: Int, hits: [FileHit], facets: FileFacets) {
        self.total = total
        self.page = page
        self.pageSize = pageSize
        self.hits = hits
        self.facets = facets
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hits = try container.decodeIfPresent([FileHit].self, forKey: .hits) ?? []
        // `total` missing is not "nothing matched" - it is a server that did
        // not say. The rows on hand are the honest floor.
        total = try container.decodeIfPresent(Int.self, forKey: .total) ?? hits.count
        page = try container.decodeIfPresent(Int.self, forKey: .page) ?? 1
        pageSize = try container.decodeIfPresent(Int.self, forKey: .pageSize) ?? hits.count
        facets = try container.decodeIfPresent(FileFacets.self, forKey: .facets) ?? .empty
    }
}

// MARK: - One file, in detail

enum FileViewerKind: String, Codable, Sendable {
    case pdf, image, text, office, none

    init(serverValue: String) {
        self = FileViewerKind(rawValue: serverValue.lowercased()) ?? .none
    }
}

struct FileDetail: Equatable, Codable, Sendable {
    let file: FileHit
    let textChars: Int?
    let extractedAt: Date?
    let previewable: Bool
    let viewer: FileViewerKind

    init(file: FileHit, textChars: Int? = nil, extractedAt: Date? = nil,
         previewable: Bool, viewer: FileViewerKind) {
        self.file = file
        self.textChars = textChars
        self.extractedAt = extractedAt
        self.previewable = previewable
        self.viewer = viewer
    }

    enum CodingKeys: String, CodingKey {
        case file, previewable, viewer
    }

    private enum FileExtraKeys: String, CodingKey {
        case textChars = "text_chars"
        case extractedAt = "extracted_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        file = try container.decode(FileHit.self, forKey: .file)
        previewable = try container.decodeIfPresent(Bool.self, forKey: .previewable) ?? false
        viewer = FileViewerKind(serverValue:
            try container.decodeIfPresent(String.self, forKey: .viewer) ?? "")
        // `text_chars` and `extracted_at` live INSIDE `file`, alongside the
        // hit's own fields, which is what "...hit, text_chars, extracted_at"
        // in the contract means.
        let extra = try container.nestedContainer(keyedBy: FileExtraKeys.self, forKey: .file)
        textChars = try extra.decodeIfPresent(Int.self, forKey: .textChars)
        extractedAt = ISO8601Time.parse(
            try extra.decodeIfPresent(String.self, forKey: .extractedAt))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(file, forKey: .file)
        try container.encode(previewable, forKey: .previewable)
        try container.encode(viewer.rawValue, forKey: .viewer)
    }
}

// MARK: - Filters

/// Exactly the parameters `/api/files/search` accepts, and nothing else.
///
/// THE SHAPE IS THE CONTRACT, on purpose. The server echoes a filter set back
/// from `/narrow`, and the app then re-sends it; anything the client invented
/// on the side (a "year" field, say) would not survive that round trip. A year
/// chip is therefore DERIVED from `since`/`until` rather than stored - see
/// `chips`.
struct FileFilters: Equatable, Codable, Sendable {
    var pods: [String] = []
    var umbrellas: [String] = []
    var projects: [String] = []
    var kinds: [FileKind] = []
    var exts: [String] = []
    var since: String?
    var until: String?
    var location: FileLocation?

    static let none = FileFilters()

    var isEmpty: Bool {
        pods.isEmpty && umbrellas.isEmpty && projects.isEmpty && kinds.isEmpty
            && exts.isEmpty && since == nil && until == nil && location == nil
    }

    enum CodingKeys: String, CodingKey {
        case pod, umbrella, project, kind, ext, since, until, location
    }

    init() {}

    init(pods: [String] = [], umbrellas: [String] = [], projects: [String] = [],
         kinds: [FileKind] = [], exts: [String] = [], since: String? = nil,
         until: String? = nil, location: FileLocation? = nil) {
        self.pods = pods
        self.umbrellas = umbrellas
        self.projects = projects
        self.kinds = kinds
        self.exts = exts
        self.since = since
        self.until = until
        self.location = location
    }

    /// Tolerant of a scalar where a list belongs.
    ///
    /// The query string takes repeated params, so a filter set the server
    /// echoes back MAY reasonably render a single value as a bare string. A
    /// browser that dropped every narrowing whose server happened to answer
    /// `"kind": "pdf"` instead of `["pdf"]` would be silently ignoring the
    /// thing the user just asked for, so both are read.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pods = Self.strings(container, .pod)
        umbrellas = Self.strings(container, .umbrella)
        projects = Self.strings(container, .project)
        kinds = Self.strings(container, .kind).map(FileKind.init(serverValue:))
        exts = Self.strings(container, .ext).map { $0.lowercased() }
        since = try container.decodeIfPresent(String.self, forKey: .since)
        until = try container.decodeIfPresent(String.self, forKey: .until)
        location = (try container.decodeIfPresent(String.self, forKey: .location))
            .map(FileLocation.init(serverValue:))
    }

    private static func strings(_ container: KeyedDecodingContainer<CodingKeys>,
                                _ key: CodingKeys) -> [String] {
        // `try?` flattens the optional the throwing call already returns, so
        // one binding covers both "the key is absent" and "it would not
        // decode as this shape".
        if let list = try? container.decodeIfPresent([String].self, forKey: key) {
            return list.filter { !$0.isEmpty }
        }
        if let single = try? container.decodeIfPresent(String.self, forKey: key),
           !single.isEmpty {
            return [single]
        }
        return []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if !pods.isEmpty { try container.encode(pods, forKey: .pod) }
        if !umbrellas.isEmpty { try container.encode(umbrellas, forKey: .umbrella) }
        if !projects.isEmpty { try container.encode(projects, forKey: .project) }
        if !kinds.isEmpty { try container.encode(kinds.map(\.rawValue), forKey: .kind) }
        if !exts.isEmpty { try container.encode(exts, forKey: .ext) }
        try container.encodeIfPresent(since, forKey: .since)
        try container.encodeIfPresent(until, forKey: .until)
        try container.encodeIfPresent(location?.rawValue, forKey: .location)
    }

    // MARK: Year, which is two fields wearing one chip

    /// The year this filter set describes, when `since` and `until` happen to
    /// bracket exactly one.
    var year: Int? {
        guard let since, let until,
              since.count == 10, until.count == 10,
              since.hasSuffix("-01-01"), until.hasSuffix("-12-31"),
              let a = Int(since.prefix(4)), let b = Int(until.prefix(4)), a == b
        else { return nil }
        return a
    }

    mutating func setYear(_ value: Int?) {
        guard let value else {
            since = nil
            until = nil
            return
        }
        since = "\(value)-01-01"
        until = "\(value)-12-31"
    }

    // MARK: Toggling

    mutating func toggle(umbrella name: String) { Self.toggle(&umbrellas, name) }
    mutating func toggle(pod name: String) { Self.toggle(&pods, name) }
    mutating func toggle(project name: String) { Self.toggle(&projects, name) }
    mutating func toggle(ext value: String) { Self.toggle(&exts, value.lowercased()) }

    mutating func toggle(kind value: FileKind) {
        if let index = kinds.firstIndex(of: value) { kinds.remove(at: index) }
        else { kinds.append(value) }
    }

    private static func toggle(_ list: inout [String], _ value: String) {
        if let index = list.firstIndex(of: value) { list.remove(at: index) }
        else { list.append(value) }
    }

    // MARK: Chips

    /// Every applied filter, as one removable chip.
    ///
    /// Order is stable and grouped: umbrella, pod, project, kind, extension,
    /// then the date bound, then location. A chip row that reorders itself
    /// when a filter is added is one the thumb cannot aim at.
    var chips: [FileFilterChip] {
        var result: [FileFilterChip] = []
        result += umbrellas.map { FileFilterChip(kind: .umbrella($0), label: $0,
                                                 symbol: "square.stack.3d.up") }
        result += pods.map { FileFilterChip(kind: .pod($0), label: $0.capitalized,
                                            symbol: "tray.full") }
        result += projects.map { FileFilterChip(kind: .project($0), label: $0,
                                                symbol: "folder") }
        result += kinds.map { FileFilterChip(kind: .fileKind($0), label: $0.title,
                                             symbol: $0.symbol) }
        result += exts.map { FileFilterChip(kind: .ext($0), label: ".\($0)",
                                            symbol: "textformat") }
        if let year {
            result.append(FileFilterChip(kind: .year(year), label: "\(year)",
                                         symbol: "calendar"))
        } else {
            if let since {
                result.append(FileFilterChip(kind: .since(since),
                                             label: "since \(since)", symbol: "calendar"))
            }
            if let until {
                result.append(FileFilterChip(kind: .until(until),
                                             label: "until \(until)", symbol: "calendar"))
            }
        }
        if let location {
            result.append(FileFilterChip(
                kind: .location(location),
                label: location.isAway ? "On the NAS" : "On this host",
                symbol: location.symbol))
        }
        return result
    }

    /// Takes one chip off. The inverse of whatever put it on, so a chip
    /// added and then removed leaves the filter set byte-identical.
    func removing(_ chip: FileFilterChip) -> FileFilters {
        var copy = self
        switch chip.kind {
        case .umbrella(let value): copy.umbrellas.removeAll { $0 == value }
        case .pod(let value): copy.pods.removeAll { $0 == value }
        case .project(let value): copy.projects.removeAll { $0 == value }
        case .fileKind(let value): copy.kinds.removeAll { $0 == value }
        case .ext(let value): copy.exts.removeAll { $0 == value }
        case .year: copy.setYear(nil)
        case .since: copy.since = nil
        case .until: copy.until = nil
        case .location: copy.location = nil
        }
        return copy
    }
}

struct FileFilterChip: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Hashable, Sendable {
        case umbrella(String)
        case pod(String)
        case project(String)
        case fileKind(FileKind)
        case ext(String)
        case year(Int)
        case since(String)
        case until(String)
        case location(FileLocation)
    }

    let kind: Kind
    let label: String
    let symbol: String

    var id: String { "\(kind)" }
}

// MARK: - Query encoding

/// The one place a filter set becomes a query string.
///
/// Pure, ordered and unit-tested, because "repeatable list params" is the kind
/// of contract detail that works in every hand test and then quietly sends
/// `kind=pdf,slides` to a server that reads it as one extension nobody has.
enum FilesQuery {

    static func items(q: String?, filters: FileFilters, sort: FileSort,
                      page: Int, pageSize: Int) -> [URLQueryItem] {
        var items: [URLQueryItem] = []
        if let q, !q.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            items.append(URLQueryItem(name: "q", value: q))
        }
        items += filters.pods.map { URLQueryItem(name: "pod", value: $0) }
        items += filters.umbrellas.map { URLQueryItem(name: "umbrella", value: $0) }
        items += filters.projects.map { URLQueryItem(name: "project", value: $0) }
        items += filters.kinds.map { URLQueryItem(name: "kind", value: $0.rawValue) }
        items += filters.exts.map { URLQueryItem(name: "ext", value: $0) }
        if let since = filters.since { items.append(URLQueryItem(name: "since", value: since)) }
        if let until = filters.until { items.append(URLQueryItem(name: "until", value: until)) }
        if let location = filters.location {
            items.append(URLQueryItem(name: "location", value: location.rawValue))
        }
        items.append(URLQueryItem(name: "sort", value: sort.rawValue))
        items.append(URLQueryItem(name: "page", value: String(page)))
        items.append(URLQueryItem(name: "page_size", value: String(pageSize)))
        return items
    }
}

/// What the browser is asking for right now.
struct FileSearchRequest: Equatable, Sendable {
    var q: String?
    var filters: FileFilters
    var sort: FileSort
    var page: Int
    var pageSize: Int

    init(q: String? = nil, filters: FileFilters = .none, sort: FileSort = .mtimeDesc,
         page: Int = 1, pageSize: Int = 30) {
        self.q = q
        self.filters = filters
        self.sort = sort
        self.page = page
        self.pageSize = pageSize
    }

    var queryItems: [URLQueryItem] {
        FilesQuery.items(q: q, filters: filters, sort: sort,
                         page: page, pageSize: pageSize)
    }

    var isSearching: Bool {
        !(q ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// MARK: - Narrowing

/// One rung of a conversational narrowing, sent back as context.
struct FileNarrowStep: Equatable, Codable, Sendable {
    let q: String
    let filters: FileFilters
}

/// What `/api/files/narrow` answers with.
///
/// `explanation` is the server's own sentence about what it did, and it is
/// shown verbatim. The app never writes that line itself: a client-invented
/// "filtered to PDFs from 2025" that does not match what the server actually
/// applied is worse than no line at all.
struct FilesNarrowing: Equatable, Sendable {
    let query: String
    let filters: FileFilters
    let explanation: String
    let result: FileSearchResult
}

extension FilesNarrowing: Decodable {
    enum CodingKeys: String, CodingKey {
        case query, filters, explanation, result
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        query = try container.decodeIfPresent(String.self, forKey: .query) ?? ""
        filters = try container.decodeIfPresent(FileFilters.self, forKey: .filters) ?? .none
        explanation = try container.decodeIfPresent(String.self, forKey: .explanation) ?? ""
        result = try container.decodeIfPresent(FileSearchResult.self, forKey: .result) ?? .empty
    }
}

// MARK: - The chat payload

/// `files: {query, filters, total}` on a chat or voice answer.
///
/// Opens the Files tile with the narrowing already applied, rather than
/// reading a list of filenames out loud.
struct FilesPayload: Equatable, Codable, Sendable {
    let query: String
    let filters: FileFilters
    let total: Int

    init(query: String, filters: FileFilters, total: Int) {
        self.query = query
        self.filters = filters
        self.total = total
    }

    enum CodingKeys: String, CodingKey { case query, filters, total }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        query = try container.decodeIfPresent(String.self, forKey: .query) ?? ""
        filters = try container.decodeIfPresent(FileFilters.self, forKey: .filters) ?? .none
        total = try container.decodeIfPresent(Int.self, forKey: .total) ?? 0
    }

    /// Built from a loose dictionary, which is what the WebSocket hands over.
    init?(json: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: json),
              let decoded = try? JSONDecoder().decode(FilesPayload.self, from: data)
        else { return nil }
        self = decoded
    }
}
