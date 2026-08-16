import Foundation

// MARK: - Freshness

/// How much a screen should trust what it is showing.
///
/// Surfaced by every feature so cached content is never presented as live —
/// with a private vault, "this is what your files said an hour ago" and "this
/// is what they say now" are materially different claims.
enum DataFreshness: Equatable {
    case live
    case demo
    case stale(Date)
    case offline(Date?)

    var bannerMessage: String? {
        switch self {
        case .live: return nil
        case .demo: return "Demo data — no backend connected."
        case .stale(let date):
            return "Showing cached data from \(RelativeTime.string(for: date)). Pull to refresh."
        case .offline(let date):
            guard let date else { return "Offline. No cached copy available." }
            return "Offline — last synced \(RelativeTime.string(for: date))."
        }
    }

    var bannerSymbol: String {
        switch self {
        case .live: return "dot.radiowaves.left.and.right"
        case .demo: return "flask"
        case .stale: return "clock.arrow.circlepath"
        case .offline: return "wifi.slash"
        }
    }

    var bannerTone: SemanticTone {
        switch self {
        case .live: return .green
        case .demo: return .cyan
        case .stale, .offline: return .amber
        }
    }

    var isLive: Bool { if case .live = self { return true }; return false }
}

/// Small indirection so models stay free of SwiftUI.
enum SemanticTone { case green, cyan, amber, red }

// MARK: - Environment

enum AppEnvironmentMode: String, Codable, CaseIterable, Identifiable {
    case demo, live
    var id: String { rawValue }
    var title: String { self == .demo ? "Demo" : "Live" }
}

/// Result of probing the configured backend.
enum ConnectionState: Equatable {
    case unknown
    case checking
    case connected(String?)      // optional server detail, e.g. the model name
    case failed(String)

    var isConnected: Bool { if case .connected = self { return true }; return false }
}

// MARK: - Documents

enum DocumentCategory: String, Codable, CaseIterable, Identifiable {
    case all, finances, health, communications, work, personal
    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All"
        case .finances: return "Finances"
        case .health: return "Health"
        case .communications: return "Comms"
        case .work: return "Work"
        case .personal: return "Personal"
        }
    }

    var symbol: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .finances: return "dollarsign.circle"
        case .health: return "heart.text.square"
        case .communications: return "bubble.left.and.bubble.right"
        case .work: return "hammer"
        case .personal: return "person.crop.circle"
        }
    }

    /// Unknown categories from a newer server become `.personal` rather than
    /// failing the whole page decode over one row.
    init(serverValue: String) {
        self = DocumentCategory(rawValue: serverValue.lowercased()) ?? .personal
    }
}

enum DocumentSort: String, CaseIterable, Identifiable {
    case documentDate, ingestDate, title
    var id: String { rawValue }

    var title: String {
        switch self {
        case .documentDate: return "Date modified"
        case .ingestDate: return "Recently indexed"
        case .title: return "Name"
        }
    }
}

/// One indexed file, as the library presents it.
///
/// `id` is opaque and assigned by the server; the client never constructs or
/// parses it, and never sends a filesystem path back. See PRIVACY.md.
struct IndexedDocument: Identifiable, Equatable, Hashable, Codable {
    let id: String
    let title: String
    let category: DocumentCategory
    let path: String
    /// Lowercase file extension, e.g. "pdf". Empty for extensionless files.
    let fileType: String
    let sizeBytes: Int64?
    let modifiedAt: Date?
    let indexedAt: Date?
    /// First few hundred characters of the indexed text. Not an LLM summary.
    let excerpt: String
    let chunkCount: Int?
    let tags: [String]
    /// Whether iOS can render this natively; drives preview vs. fallback.
    let previewable: Bool

    /// Shown on a card when the excerpt has not been loaded yet.
    var subtitleFallback: String {
        fileType.isEmpty ? "Indexed file" : "\(fileType.uppercased()) document"
    }
}

/// A page of library results plus the counts the filter row needs.
struct DocumentLibraryPage: Equatable {
    let documents: [IndexedDocument]
    /// Matching the current filter.
    let total: Int
    /// In the vault, before filtering.
    let indexedTotal: Int
    let categoryCounts: [DocumentCategory: Int]

    static let empty = DocumentLibraryPage(documents: [], total: 0,
                                           indexedTotal: 0, categoryCounts: [:])
}

/// A downloaded document, ready to preview or share.
///
/// `isReconstructed` records that the server could not read the original file
/// and returned text rebuilt from the index instead. The UI must say so: the
/// user is about to share this, and "the PDF" and "the text extracted from the
/// PDF" are not the same artefact.
struct DocumentPayload: Equatable {
    let url: URL
    let isReconstructed: Bool
}

// MARK: - Voice

/// One spoken exchange, kept for the session's transcript.
/// A document an answer pulled up, resolvable on the phone.
///
/// The id is the server's stable sha1(path) handle - a vault path is NOT
/// fetchable, because /documents/{id} resolves by that hash and nothing else.
struct DocumentRef: Equatable, Identifiable {
    let id: String
    let title: String
    let fileType: String
    let previewable: Bool
}

struct VoiceExchange: Identifiable, Equatable {
    let id: String
    let question: String
    let answer: String
    let source: String?
    /// Set when the turn pulled a file up, so it can be opened here rather
    /// than only on the wall display.
    let document: DocumentRef?
    let askedAt: Date

    init(id: String = UUID().uuidString,
         question: String,
         answer: String,
         source: String?,
         document: DocumentRef? = nil,
         askedAt: Date = Date()) {
        self.id = id
        self.question = question
        self.answer = answer
        self.source = source
        self.document = document
        self.askedAt = askedAt
    }
}

/// What the assistant is doing. This is what the orb animates.
enum VoicePhase: Equatable {
    case idle
    case listening
    case thinking
    case speaking
    case failed(String)

    var label: String {
        switch self {
        case .idle: return "Hold to ask"
        case .listening: return "Listening"
        // Not necessarily a file search - the answer may come from mail, the
        // calendar or the web, so name the state after the work, not a source.
        case .thinking: return "Thinking"
        case .speaking: return "Answering"
        case .failed: return "Something went wrong"
        }
    }

    var isBusy: Bool {
        switch self {
        case .thinking, .speaking: return true
        default: return false
        }
    }

    var allowsNewQuestion: Bool {
        switch self {
        case .idle, .failed: return true
        default: return false
        }
    }
}

/// The spoken answer plus the audio to play for it.
struct SpokenAnswer: Equatable {
    let text: String
    let source: String?
    /// Local file the player reads. Nil when the server had no voice engine,
    /// in which case the client falls back to on-device speech.
    let audioURL: URL?
}

// MARK: - Morning call

/// When the morning call rings, and for which day.
///
/// Times stay as "HH:MM" strings end to end rather than becoming `Date`s. The
/// server schedules against a wall clock in its own timezone, and a `Date`
/// round-trip through this device's timezone is how 07:00 becomes 06:00 after
/// a flight. The picker converts once, for display and for editing, and never
/// stores the result.
/// Whether the phone should be offering to say "I'm up", and whether saying it
/// would be recorded.
///
/// Two separate answers on purpose, and the server owns both. On the morning of
/// 2026-08-16 he answered the call in his sleep, never spoke, and the redial
/// ladder correctly re-armed and spent all six attempts; the button is the
/// deliberate way to end that without talking. `inCallWindow` is the tight one
/// - roughly a redial interval after the last ring - and is what decides
/// whether a banner appears. `canConfirm` is the six-hour bound the server
/// enforces on writing, so a confirmation is still recorded honestly against
/// the right morning long after the banner has gone.
struct MorningCallState: Equatable {
    let inCallWindow: Bool
    let canConfirm: Bool
    let confirmed: Bool

    /// No call, nothing to offer. Also what every backend without this
    /// endpoint reports, so the banner simply never appears rather than the
    /// screen having to know whether the server is new enough.
    static let inactive = MorningCallState(inCallWindow: false,
                                           canConfirm: false, confirmed: false)
}

struct MorningSchedule: Equatable {
    /// 24-hour "HH:MM", the time the call is currently set for.
    let callTime: String
    /// "YYYY-MM-DD" the override applies to, or nil when `callTime` is just
    /// the standing default and no particular day has been overridden.
    let date: String?
    /// The standing time, so the screen can say when an override differs
    /// from it and offer to go back.
    let defaultTime: String

    /// "7:30am" - what the confirmation says, in the form he reads a clock.
    static func display(_ time: String) -> String {
        let parts = time.split(separator: ":")
        guard parts.count >= 2, let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0...23).contains(hour), (0...59).contains(minute) else { return time }
        let suffix = hour < 12 ? "am" : "pm"
        let twelve = hour % 12 == 0 ? 12 : hour % 12
        return minute == 0 ? "\(twelve)\(suffix)"
                           : String(format: "%d:%02d%@", twelve, minute, suffix)
    }
}
