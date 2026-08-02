import Foundation

/// The single boundary between features and data.
///
/// Demo and Live implement this identically, so every screen, state and test
/// path is exercised without a backend running.
protocol ATARUService: AnyObject, Sendable {

    /// Probes the backend. Returns an optional detail string (model name,
    /// version) for the Settings screen.
    func checkStatus() async throws -> String?

    // MARK: Documents

    func documents(query: String?, category: DocumentCategory) async throws -> DocumentLibraryPage
    func document(id: String) async throws -> IndexedDocument

    /// Downloads a document to a local file for preview and sharing.
    ///
    /// Returns a URL the caller owns and is responsible for discarding — see
    /// `DocumentDownloadStore`, which keeps these in a single scratch
    /// directory that is emptied when the app leaves the foreground.
    func documentContent(id: String) async throws -> DocumentPayload

    // MARK: Voice

    /// Asks a question and returns the answer with server-rendered audio.
    ///
    /// The audio matters: it is the same Piper voice the telephone front door
    /// uses, so the two ways in sound like one assistant. When the server has
    /// no voice engine the payload carries text only and the caller falls back
    /// to on-device speech.
    func ask(question: String) async throws -> SpokenAnswer

    /// Opens a streaming voice session, or nil when the backend has none.
    ///
    /// Streaming is how a call answers fast: sentence audio plays while the
    /// model is still generating the rest. `ask(question:)` stays as the
    /// fallback for backends (and failures) without it, so callers must treat
    /// nil and a broken stream identically — degrade, never fail the question.
    func voiceStream() -> VoiceStreamSession?

    /// Names the speech recogniser should expect, biasing it toward the
    /// people Arya actually deals with. Empty is fine - it just means
    /// unbiased transcription, which is where this started.
    func vocabulary() async throws -> [String]

    /// The call's opening line, ideally in the server's voice.
    ///
    /// A call that greets in an iOS voice and answers in the server's sounds
    /// like two assistants. Backends render the greeting through their own
    /// TTS; the default is text-only, which callers speak locally - the same
    /// graceful degradation as every other voice path.
    func greeting() async throws -> SpokenAnswer

    /// The call's closing line, spoken when the caller says they're done.
    func goodbye() async throws -> SpokenAnswer

    // MARK: Plan

    /// Today's plan - the three main things plus the todo list. The same
    /// vault file the morning call announces and writes by voice; the Plan
    /// tile is a third view of one list.
    func plan() async throws -> DailyPlan
    func planAdd(_ text: String, top3: Bool) async throws -> DailyPlan
    func planSetDone(section: String, index: Int, done: Bool) async throws -> DailyPlan
    func planRemove(section: String, index: Int) async throws -> DailyPlan

    // MARK: Calls

    /// Hands the server the PushKit token it needs to ring this phone.
    ///
    /// Sent on every launch rather than once: iOS issues a new token after a
    /// reinstall, a restore, or at its own discretion, and a stale token fails
    /// silently — the phone simply never rings, and nothing surfaces anywhere
    /// the user would think to look.
    func registerVoIPToken(_ token: String, environment: String) async throws
}

extension ATARUService {
    /// Backends without streaming (Demo) inherit the blocking path.
    func voiceStream() -> VoiceStreamSession? { nil }

    /// Backends without a plan store report an empty day rather than failing;
    /// the tile renders its empty state and the rest of the app is untouched.
    /// (Also keeps the test stubs compiling without learning the vocabulary.)
    func plan() async throws -> DailyPlan { .empty() }
    func planAdd(_ text: String, top3: Bool) async throws -> DailyPlan { .empty() }
    func planSetDone(section: String, index: Int, done: Bool) async throws -> DailyPlan { .empty() }
    func planRemove(section: String, index: Int) async throws -> DailyPlan { .empty() }

    /// Backends without a voice engine greet in the phone's voice.
    func greeting() async throws -> SpokenAnswer {
        SpokenAnswer(text: "ATARU here. What would you like to know?",
                     source: nil, audioURL: nil)
    }

    /// Backends without a voice engine say goodbye in the phone's voice.
    func goodbye() async throws -> SpokenAnswer {
        SpokenAnswer(text: "Alright, talk later.", source: nil, audioURL: nil)
    }
}

/// Client-side filtering and sorting.
///
/// The server already filters, but the client repeats it so Demo behaves
/// exactly like Live and so typing in the search field feels instant instead
/// of waiting on a round trip. Pure and unit-tested.
enum DocumentQuery {

    static func filter(_ documents: [IndexedDocument],
                       query: String?,
                       category: DocumentCategory) -> [IndexedDocument] {
        var result = documents
        if category != .all {
            result = result.filter { $0.category == category }
        }
        if let query {
            let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !needle.isEmpty {
                result = result.filter { document in
                    document.title.lowercased().contains(needle)
                        || document.path.lowercased().contains(needle)
                        || document.excerpt.lowercased().contains(needle)
                        || document.tags.contains { $0.lowercased().contains(needle) }
                }
            }
        }
        return result
    }

    static func sort(_ documents: [IndexedDocument], by order: DocumentSort) -> [IndexedDocument] {
        switch order {
        case .documentDate:
            // Unknown dates sort last rather than jumping to the top, which is
            // what `.distantPast` in a descending sort would otherwise do.
            return documents.sorted { ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) }
        case .ingestDate:
            return documents.sorted { ($0.indexedAt ?? .distantPast) > ($1.indexedAt ?? .distantPast) }
        case .title:
            return documents.sorted {
                $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
        }
    }

    static func apply(_ documents: [IndexedDocument],
                      query: String?,
                      category: DocumentCategory,
                      sort order: DocumentSort) -> [IndexedDocument] {
        sort(filter(documents, query: query, category: category), by: order)
    }

    /// Counts per category, for the filter chips. Always includes every
    /// category so the row does not reflow as the vault changes.
    static func counts(_ documents: [IndexedDocument]) -> [DocumentCategory: Int] {
        var counts: [DocumentCategory: Int] = [:]
        for category in DocumentCategory.allCases where category != .all {
            counts[category] = 0
        }
        for document in documents {
            counts[document.category, default: 0] += 1
        }
        counts[.all] = documents.count
        return counts
    }
}
