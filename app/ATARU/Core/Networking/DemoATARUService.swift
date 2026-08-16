import Foundation

/// A complete ATARU backend, in-process.
///
/// This exists so the app can be opened, reviewed and UI-tested on a machine
/// that has never seen the real server — and so every state the UI can enter
/// (slow response, empty result, missing file, no voice engine) is reachable
/// deliberately instead of only by breaking something.
///
/// The fixtures are synthetic. Nothing here came from a real vault: no real
/// names, addresses, account numbers or medical values. See PRIVACY.md.
final class DemoATARUService: ATARUService, @unchecked Sendable {

    /// Simulated round-trip. Roughly what the Jetson takes for a fast-tier
    /// answer, so the demo doesn't feel misleadingly instant.
    private let latency: Duration
    private let downloads: DocumentDownloadStore
    private let documentsFixture: [IndexedDocument]

    init(latency: Duration = .milliseconds(600),
         downloads: DocumentDownloadStore = .shared) {
        self.latency = latency
        self.downloads = downloads
        self.documentsFixture = DemoFixtures.documents()
    }

    func checkStatus() async throws -> String? {
        try await pause()
        return "ok (demo)"
    }

    func documents(query: String?, category: DocumentCategory) async throws -> DocumentLibraryPage {
        try await pause()
        let matched = DocumentQuery.filter(documentsFixture, query: query, category: category)
        return DocumentLibraryPage(
            documents: matched,
            total: matched.count,
            indexedTotal: documentsFixture.count,
            categoryCounts: DocumentQuery.counts(documentsFixture)
        )
    }

    func document(id: String) async throws -> IndexedDocument {
        try await pause()
        guard let match = documentsFixture.first(where: { $0.id == id }) else {
            throw APIError.notFound
        }
        return match
    }

    func documentContent(id: String) async throws -> DocumentPayload {
        try await pause()
        let document = try await self.document(id: id)
        let body = DemoFixtures.body(for: document)
        let url = try await downloads.store(Data(body.utf8),
                                            preferredName: "\(document.title).txt")
        // Demo has no original files, only text — which is exactly the
        // reconstructed case, so the banner it drives is exercised here too.
        return DocumentPayload(url: url, isReconstructed: true)
    }

    func ask(question: String) async throws -> SpokenAnswer {
        try await pause()
        try await Task.sleep(for: .milliseconds(900))   // retrieval + generation
        let (answer, source) = DemoFixtures.answer(for: question)
        // No audio: demo mode has no Piper, which drives the same on-device
        // speech fallback a server without a voice engine would.
        return SpokenAnswer(text: answer, source: source, audioURL: nil)
    }

    /// Accepted and discarded. Demo mode has no server, so there is nothing to
    /// ring this phone — but failing here would surface a registration error in
    /// Settings for a mode where being un-ringable is the expected state.
    /// Demo mode biases nothing: there is no real correspondent list, and
    /// inventing one would train the recogniser on names that do not exist.
    func vocabulary() async throws -> [String] { [] }

    /// Demo has no server to transcribe on, so the caller keeps whatever the
    /// phone heard by itself.
    func transcribe(samples: [Float]) async -> String? { nil }

    func registerVoIPToken(_ token: String, environment: String) async throws {}

    // MARK: Plan (in-memory)

    /// A working plan, so the tile is fully exercisable in Demo: add, check
    /// off, remove - state lives for the process and resets on relaunch,
    /// which is exactly what a demo wants.
    private static let planLock = NSLock()
    nonisolated(unsafe) private static var planState = DailyPlan(
        date: DailyPlan.todayKey,
        top3: [PlanItem(text: "Review the demo pull request", done: false),
               PlanItem(text: "Gym before lunch", done: true),
               PlanItem(text: "Ship the sandbox build", done: false)],
        also: [PlanItem(text: "Water the plants", done: false)])

    private func withPlan(_ mutate: (DailyPlan) -> DailyPlan) -> DailyPlan {
        Self.planLock.lock()
        defer { Self.planLock.unlock() }
        Self.planState = mutate(Self.planState)
        return Self.planState
    }

    /// Demo parses locally, so the Notes screen has something to show without
    /// a backend: anything that reads as an instruction becomes a task, and
    /// the rest of the note stays a note. Deliberately dumber than the real
    /// route - it is a fixture, not a second implementation to keep in step.
    func parseTasks(transcript: String) async throws -> [NoteTask] {
        try await pause()
        let verbs = ["call", "email", "book", "buy", "send", "pay", "check",
                     "renew", "fix", "write", "ask", "order", "pick up",
                     "remember to", "need to", "finish", "review", "schedule"]
        return NoteDigest.points(in: transcript).compactMap { point in
            let lowered = point.lowercased()
            guard verbs.contains(where: { lowered.contains($0) }) else { return nil }
            return NoteTask(title: point,
                            category: lowered.contains("pay")
                                || lowered.contains("bank") ? "Finance" : "Personal")
        }
    }

    func plan() async throws -> DailyPlan {
        try await pause()
        return withPlan { $0 }
    }

    func planAdd(_ text: String, top3: Bool) async throws -> DailyPlan {
        try await pause()
        return withPlan { plan in
            var top = plan.top3, rest = plan.also
            if top3, top.count < 3 { top.append(PlanItem(text: text, done: false)) }
            else { rest.append(PlanItem(text: text, done: false)) }
            return DailyPlan(date: plan.date, top3: top, also: rest)
        }
    }

    func planSetDone(section: String, index: Int, done: Bool) async throws -> DailyPlan {
        try await pause()
        return withPlan { plan in
            var top = plan.top3, rest = plan.also
            if section == "top3", top.indices.contains(index) {
                top[index] = PlanItem(text: top[index].text, done: done)
            } else if section == "also", rest.indices.contains(index) {
                rest[index] = PlanItem(text: rest[index].text, done: done)
            }
            return DailyPlan(date: plan.date, top3: top, also: rest)
        }
    }

    func planRemove(section: String, index: Int) async throws -> DailyPlan {
        try await pause()
        return withPlan { plan in
            var top = plan.top3, rest = plan.also
            if section == "top3", top.indices.contains(index) { top.remove(at: index) }
            else if section == "also", rest.indices.contains(index) { rest.remove(at: index) }
            return DailyPlan(date: plan.date, top3: top, also: rest)
        }
    }

    private func pause() async throws {
        try await Task.sleep(for: latency)
    }
}

/// Synthetic content for Demo mode.
enum DemoFixtures {

    static func documents() -> [IndexedDocument] {
        let now = Date()
        func ago(days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }

        return [
            IndexedDocument(
                id: "demo-001", title: "System Architecture.md", category: .work,
                path: "records/work/home-stack/System Architecture.md", fileType: "md",
                sizeBytes: 18_422, modifiedAt: ago(days: 9), indexedAt: ago(days: 0.3),
                excerpt: "Reference architecture for the home stack: the always-on orchestrator, the accelerator node used for retrieval and local inference, and the NAS that holds the vault of record.",
                chunkCount: 14, tags: ["architecture", "infrastructure"], previewable: true),
            IndexedDocument(
                id: "demo-002", title: "Home Server Build Notes.md", category: .work,
                path: "records/work/home-stack/Home Server Build Notes.md", fileType: "md",
                sizeBytes: 24_880, modifiedAt: ago(days: 14), indexedAt: ago(days: 0.3),
                excerpt: "Running build log: drive layout, boot media and fallback image, UPS wiring, and the network path from the aggregation switch. Records what was tried and what was rejected.",
                chunkCount: 19, tags: ["build-log", "hardware"], previewable: true),
            IndexedDocument(
                id: "demo-003", title: "Sample Lab Panel.pdf", category: .health,
                path: "records/health/labs/Sample Lab Panel.pdf", fileType: "pdf",
                sizeBytes: 88_604, modifiedAt: ago(days: 26), indexedAt: ago(days: 1.3),
                excerpt: "Routine metabolic panel with three reported markers and their laboratory reference ranges. Values are shown as recorded; interpretation belongs with a clinician.",
                chunkCount: 4, tags: ["labs", "reference-range"], previewable: true),
            IndexedDocument(
                id: "demo-004", title: "Quarterly Budget Summary.pdf", category: .finances,
                path: "records/finances/budget/Quarterly Budget Summary.pdf", fileType: "pdf",
                sizeBytes: 142_336, modifiedAt: ago(days: 21), indexedAt: ago(days: 2.2),
                excerpt: "Quarter-over-quarter spending by category with recurring-subscription totals and a note on which renewals fall inside the next billing window.",
                chunkCount: 8, tags: ["budget", "quarterly"], previewable: true),
            IndexedDocument(
                id: "demo-005", title: "Project Retrospective.md", category: .work,
                path: "records/work/projects/Project Retrospective.md", fileType: "md",
                sizeBytes: 11_204, modifiedAt: ago(days: 5), indexedAt: ago(days: 0.8),
                excerpt: "Retrospective for the indexing pipeline rebuild: what shipped, the two regressions found in review, and the follow-up items that were deferred rather than dropped.",
                chunkCount: 9, tags: ["retrospective"], previewable: true),
            IndexedDocument(
                id: "demo-006", title: "Travel Checklist.md", category: .personal,
                path: "records/personal/travel/Travel Checklist.md", fileType: "md",
                sizeBytes: 4_820, modifiedAt: ago(days: 40), indexedAt: ago(days: 3.1),
                excerpt: "Reusable packing and pre-departure checklist, including document copies, chargers by device, and the day-before verification list.",
                chunkCount: 3, tags: ["travel"], previewable: true),
            IndexedDocument(
                id: "demo-007", title: "Landlord Correspondence Summary.md", category: .communications,
                path: "records/communications/housing/Landlord Correspondence Summary.md", fileType: "md",
                sizeBytes: 6_140, modifiedAt: ago(days: 3), indexedAt: ago(days: 0.35),
                excerpt: "Condensed thread summary covering the maintenance request, the scheduling reply, and the outstanding question about the inspection window.",
                chunkCount: 5, tags: ["housing"], previewable: true),
            IndexedDocument(
                id: "demo-008", title: "Vault Backup Policy.md", category: .work,
                path: "records/work/home-stack/Vault Backup Policy.md", fileType: "md",
                sizeBytes: 9_330, modifiedAt: ago(days: 33), indexedAt: ago(days: 4.0),
                excerpt: "Backup and restore policy: snapshot cadence, retention windows, the offsite copy, and the quarterly restore drill that verifies the whole chain.",
                chunkCount: 7, tags: ["backup", "policy"], previewable: true),
            IndexedDocument(
                id: "demo-009", title: "Subscription Inventory.pdf", category: .finances,
                path: "records/finances/subscriptions/Subscription Inventory.pdf", fileType: "pdf",
                sizeBytes: 74_112, modifiedAt: ago(days: 12), indexedAt: ago(days: 1.1),
                excerpt: "Every detected recurring charge with its renewal date and billing cadence. Flags two services with overlapping functionality.",
                chunkCount: 6, tags: ["subscriptions"], previewable: true),
            IndexedDocument(
                id: "demo-010", title: "Reading Notes.md", category: .personal,
                path: "records/personal/notes/Reading Notes.md", fileType: "md",
                sizeBytes: 15_760, modifiedAt: ago(days: 7), indexedAt: ago(days: 1.8),
                excerpt: "Working notes and quotations collected while reading, grouped by theme with page locators for later citation.",
                chunkCount: 11, tags: ["notes"], previewable: true),
            // An unsupported type, so the "no native preview" state is
            // reachable in Demo without breaking anything.
            IndexedDocument(
                id: "demo-011", title: "Spending Model.xlsx", category: .finances,
                path: "records/finances/budget/Spending Model.xlsx", fileType: "xlsx",
                sizeBytes: 51_200, modifiedAt: ago(days: 30), indexedAt: ago(days: 2.6),
                excerpt: "Spreadsheet model behind the quarterly summary: category rollups, renewal calendar, and the sensitivity table.",
                chunkCount: 2, tags: ["budget", "model"], previewable: false)
        ]
    }

    static func body(for document: IndexedDocument) -> String {
        """
        \(document.title)
        \(String(repeating: "=", count: document.title.count))

        \(document.excerpt)

        This is synthetic demo content. Connect ATARU to your own server in
        Settings to browse your real indexed documents.

        Path:     \(document.path)
        Category: \(document.category.title)
        Chunks:   \(document.chunkCount.map(String.init) ?? "unknown")
        """
    }

    /// Canned answers keyed loosely off the question, so Demo responds to what
    /// was actually asked rather than always returning the same paragraph.
    static func answer(for question: String) -> (String, String?) {
        let asked = question.lowercased()
        if asked.contains("backup") || asked.contains("restore") {
            return ("Snapshots run nightly with a thirty-day retention window, plus an offsite copy. A restore drill runs quarterly to verify the whole chain.",
                    "records/work/home-stack/Vault Backup Policy.md")
        }
        if asked.contains("subscription") || asked.contains("renew") {
            return ("Two subscriptions renew within the next two weeks, and two services overlap in functionality.",
                    "records/finances/subscriptions/Subscription Inventory.pdf")
        }
        if asked.contains("landlord") || asked.contains("inspection") {
            return ("The thread is waiting on you to confirm an inspection window. The maintenance request itself was already scheduled.",
                    "records/communications/housing/Landlord Correspondence Summary.md")
        }
        if asked.isEmpty {
            return ("I didn't catch a question. Hold the button and speak, then let go.", nil)
        }
        return ("This is Demo mode, so I'm answering from sample files rather than your vault. Connect your server in Settings to ask about your own documents.",
                "records/work/home-stack/System Architecture.md")
    }
}
