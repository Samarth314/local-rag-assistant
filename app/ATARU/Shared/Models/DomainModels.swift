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
struct VoiceExchange: Identifiable, Equatable {
    let id: String
    let question: String
    let answer: String
    let source: String?
    let askedAt: Date

    init(id: String = UUID().uuidString,
         question: String,
         answer: String,
         source: String?,
         askedAt: Date = Date()) {
        self.id = id
        self.question = question
        self.answer = answer
        self.source = source
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
        case .thinking: return "Searching your files"
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
