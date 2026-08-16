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

    /// A turn's audio, transcribed server-side against that same roster.
    ///
    /// Returns nil rather than throwing: every caller has a working local
    /// fallback behind this, and a transcription path that can fail loudly
    /// mid-call is worse than one that quietly hands back.
    func transcribe(samples: [Float]) async -> String?

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

    // MARK: Morning call

    /// When tomorrow's first morning call is set to ring.
    ///
    /// The call itself is scheduled server-side; this is only the dial. See
    /// `setMorningSchedule` for why the default throws rather than guessing.
    func morningSchedule() async throws -> MorningSchedule

    /// Turns a dictated note into structured, tickable tasks.
    ///
    /// The transcript goes up as TEXT and structure comes back - the server
    /// owns the model, exactly as in FlowList. Audio is never involved: see
    /// SpeechDictation.finishLocally for why a note's capture path ends at the
    /// recogniser.
    func parseTasks(transcript: String) async throws -> [NoteTask]

    /// Sets the call time, for `date` or - when that is nil - for tomorrow.
    ///
    /// Deliberately has NO default implementation that pretends to succeed. A
    /// backend without this endpoint must surface as an error the screen can
    /// report honestly, because the failure mode of quietly accepting a time
    /// that was never stored is a phone that does not ring in the morning and
    /// nothing anywhere saying why.
    func setMorningSchedule(callTime: String, date: String?) async throws -> MorningSchedule

    /// "I'm up" - the button that stands the redial ladder down without him
    /// having to speak.
    ///
    /// Returns whether the server actually recorded it. False is not an error:
    /// it means no morning call was in flight, and the honest answer is "there
    /// was nothing to confirm" rather than a success the user would reasonably
    /// read as "the calls will stop now".
    ///
    /// SPEECH STILL CONFIRMS, exactly as before. This is an additional path,
    /// for the mornings where he is awake but not talking - 2026-08-16 he
    /// answered in his sleep, said nothing, and the ladder spent all six
    /// attempts, which was the ladder being right.
    @discardableResult
    func confirmMorningCall() async throws -> Bool

    /// Whether to offer the button at all. Cheap, read-only, polled when the
    /// app comes to the foreground.
    func morningCallState() async throws -> MorningCallState

    // MARK: Calls

    /// Hands the server the PushKit token it needs to ring this phone.
    ///
    /// Sent on every launch rather than once: iOS issues a new token after a
    /// reinstall, a restore, or at its own discretion, and a stale token fails
    /// silently — the phone simply never rings, and nothing surfaces anywhere
    /// the user would think to look.
    func registerVoIPToken(_ token: String, environment: String) async throws

    /// Hands the server the APNs token for ordinary notifications - the ones
    /// that used to arrive from ntfy.
    ///
    /// A DIFFERENT token from `registerVoIPToken`'s, and not interchangeable:
    /// PushKit issues its own, and sending a notification to a VoIP token (or
    /// the reverse) fails. Both go to the same APNs key, hence the same
    /// `environment` argument telling the server which host to use.
    ///
    /// Called on every launch, because that is when iOS hands over a token and
    /// the token can rotate at Apple's discretion. The endpoint is idempotent.
    func registerPushToken(_ token: String, environment: String) async throws
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

    /// Backends without the morning endpoint report it missing rather than
    /// inventing a time. `notFound` is what the screen turns into "not
    /// available yet", and it is also exactly what a server that has not
    /// deployed the route yet returns on its own.
    func morningSchedule() async throws -> MorningSchedule {
        throw APIError.notFound
    }

    /// Backends without the route say so, rather than returning no tasks.
    ///
    /// The distinction matters to the caller: "this server cannot parse tasks"
    /// leaves the note's own bullets standing as checkboxes, while an empty
    /// array would mean "parsed it, found nothing" and replace them with
    /// nothing. See NoteStore.adopt.
    func parseTasks(transcript: String) async throws -> [NoteTask] {
        throw APIError.notFound
    }

    func setMorningSchedule(callTime: String, date: String?) async throws -> MorningSchedule {
        throw APIError.notFound
    }

    /// A backend without the confirm route records nothing, and says so by
    /// returning false rather than throwing. The distinction the UI needs is
    /// "it counted" vs "it did not", and an old server is the same answer as
    /// no call in flight: nothing was recorded.
    @discardableResult
    func confirmMorningCall() async throws -> Bool { false }

    /// Nothing to offer, which is what a backend without the route means and
    /// exactly what the banner should do about it.
    func morningCallState() async throws -> MorningCallState { .inactive }

    /// Backends with nowhere to send a notification accept the token and do
    /// nothing with it. Demo is the real case - there is no server to register
    /// with - and quietly succeeding is right there, because nothing in the
    /// app depends on registration having happened. (It also keeps the test
    /// stubs compiling without learning the vocabulary.)
    func registerPushToken(_ token: String, environment: String) async throws {}
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
