import Foundation
import SwiftUI

/// Drives the Files browser: one page at a time, filters as chips, and a
/// conversational narrowing on top of both.
///
/// UNLIKE THE VAULT LIBRARY, nothing is filtered on device. `DocumentsViewModel`
/// fetches the whole vault once and filters locally, which is right for a few
/// hundred records and wrong for a project tree: the server owns the index, the
/// counts and the relevance, and a client that re-derived any of them would
/// disagree with the facets it is drawing the rails from.
@MainActor
final class FilesViewModel: ObservableObject {

    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    /// What the browser is reading, and what it last read.
    @Published private(set) var state: LoadState = .idle
    @Published private(set) var hits: [FileHit] = []
    @Published private(set) var total = 0
    @Published private(set) var facets: FileFacets = .empty
    @Published private(set) var isLoadingMore = false
    /// The server's own sentence about the last narrowing. Never written here.
    @Published private(set) var explanation: String?
    /// When the rows on screen were last read from a server. Nil while they
    /// came straight out of the cache and nothing has answered yet.
    @Published private(set) var cachedAt: Date?

    /// The search field. Committing it (return, or the debounce) searches.
    @Published var query: String = ""
    @Published private(set) var filters: FileFilters = .none
    @Published var sort: FileSort = .mtimeDesc {
        didSet {
            guard sort != oldValue, !isMutatingQuietly else { return }
            reload()
        }
    }

    /// Every rung of the narrowing so far, oldest first, as the server wants
    /// it. Cleared whenever the browser is reset by hand - a chip removed by
    /// thumb is not part of a conversation.
    @Published private(set) var history: [FileNarrowStep] = []

    /// What the query was when the rows on screen were fetched. The search
    /// field can be typed into without the list changing under it, so the two
    /// are deliberately different values.
    private var appliedQuery: String?
    private var page = 1
    private var pageSize = 30
    private var service: ATARUService?
    private var cacheRoot: URL?
    private var loadTask: Task<Void, Never>?
    private var debounce: Task<Void, Never>?

    static let cacheKind = "files"

    // MARK: - Wiring

    func configure(service: ATARUService, cacheRoot: URL?) {
        let changed = self.service !== service
        self.service = service
        self.cacheRoot = cacheRoot
        guard changed else { return }
        // A request in flight captured the OLD backend and would publish its
        // rows into this session - the browser would be showing one server's
        // files under the other's name. Same hazard `DocumentsViewModel.update`
        // fixes, same answer.
        loadTask?.cancel()
        loadTask = nil
        hits = []
        total = 0
        facets = .empty
        explanation = nil
        history = []
        state = .idle
    }

    /// Draws the last listing before the network is asked anything.
    ///
    /// Only ever a first paint: as soon as a real answer lands it replaces
    /// this wholesale, and `cachedAt` is what the screen says while it waits.
    func restore() async {
        guard hits.isEmpty, state == .idle,
              let cached = await TileCache.load(Cached.self, kind: Self.cacheKind,
                                                for: cacheRoot)
        else { return }
        hits = cached.payload.hits
        total = cached.payload.total
        facets = cached.payload.facets
        filters = cached.payload.filters
        appliedQuery = cached.payload.query
        query = cached.payload.query ?? ""
        sortWithoutReloading(cached.payload.sort)
        cachedAt = cached.savedAt
    }

    /// Moves the sort without triggering the fetch its observer would.
    ///
    /// Three callers, all of which are ALREADY about to fetch (or have just
    /// restored a listing that was sorted this way): committing a query,
    /// applying a payload, and restoring the cache. Letting the observer fire
    /// there costs a second request for the same rows, and the two can land
    /// out of order.
    private func sortWithoutReloading(_ value: FileSort) {
        guard sort != value else { return }
        isMutatingQuietly = true
        sort = value
        isMutatingQuietly = false
    }

    private var isMutatingQuietly = false

    // MARK: - Reading

    var request: FileSearchRequest {
        FileSearchRequest(q: appliedQuery, filters: filters, sort: sort,
                          page: page, pageSize: pageSize)
    }

    var isSearching: Bool {
        !(appliedQuery ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasMore: Bool { hits.count < total }

    var isEmpty: Bool { state == .loaded && hits.isEmpty }

    /// What went wrong last, when there is still a listing on screen. A failed
    /// refresh over loaded rows is a lost round trip, not an empty index.
    var refreshFailure: String? {
        guard case .failed(let message) = state, !hits.isEmpty else { return nil }
        return message
    }

    var countLabel: String {
        if total == 0 { return "No files" }
        let noun = total == 1 ? "file" : "files"
        return hits.count >= total ? "\(total) \(noun)" : "\(hits.count) of \(total)"
    }

    func reload() {
        page = 1
        load(replacing: true)
    }

    func loadMore() {
        guard hasMore, !isLoadingMore, state != .loading else { return }
        page += 1
        load(replacing: false)
    }

    private func load(replacing: Bool) {
        guard let service else { return }
        loadTask?.cancel()
        if replacing { state = .loading } else { isLoadingMore = true }
        let request = self.request
        loadTask = Task { [weak self] in
            do {
                let result = try await service.filesSearch(request)
                guard !Task.isCancelled, let self else { return }
                self.adopt(result, replacing: replacing)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.isLoadingMore = false
                // A failed "load more" must not roll the page number forward,
                // or the next attempt silently skips a page of results.
                if !replacing { self.page = max(1, self.page - 1) }
                self.state = .failed((error as? APIError)?.localizedDescription
                                     ?? error.localizedDescription)
            }
        }
    }

    private func adopt(_ result: FileSearchResult, replacing: Bool) {
        if replacing {
            hits = result.hits
        } else {
            // De-duplicated by id: a page boundary that moves between two
            // requests (a file touched while browsing) otherwise repeats a row.
            let known = Set(hits.map(\.id))
            hits += result.hits.filter { !known.contains($0.id) }
        }
        total = result.total
        pageSize = max(1, result.pageSize)
        // Facets describe the whole match set, so a "load more" must not
        // replace them with a narrower view built from one page - except that
        // the server computes them over the match set every time, so taking
        // the newest is correct and taking the oldest would go stale.
        if !result.facets.isEmpty || replacing { facets = result.facets }
        isLoadingMore = false
        state = .loaded
        cachedAt = nil
        save()
    }

    // MARK: - Query

    /// Typing. Debounced rather than per-keystroke: this is a server search.
    func queryChanged() {
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            self?.submitQuery()
        }
    }

    func submitQuery() {
        debounce?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let next = trimmed.isEmpty ? nil : trimmed
        guard next != appliedQuery else { return }
        appliedQuery = next
        // Relevance only means something with a query, and "recent" is the
        // only order that means anything without one.
        if next == nil, sort == .relevance { sortWithoutReloading(.mtimeDesc) }
        if next != nil, sort == .mtimeDesc { sortWithoutReloading(.relevance) }
        explanation = nil
        reload()
    }

    // MARK: - Filters

    func toggle(umbrella name: String) {
        filters.toggle(umbrella: name)
        reload()
    }

    func toggle(pod name: String) {
        filters.toggle(pod: name)
        reload()
    }

    func toggle(kind value: FileKind) {
        filters.toggle(kind: value)
        reload()
    }

    func toggle(year value: Int) {
        filters.setYear(filters.year == value ? nil : value)
        reload()
    }

    func remove(_ chip: FileFilterChip) {
        filters = filters.removing(chip)
        // A chip taken off by thumb ends the conversation: the explanation on
        // screen described a filter set that no longer exists, and leaving it
        // there would have the server appearing to claim something untrue.
        explanation = nil
        history = []
        reload()
    }

    func clearFilters() {
        filters = .none
        explanation = nil
        history = []
        reload()
    }

    var isFiltered: Bool { !filters.isEmpty || isSearching }

    // MARK: - Narrowing

    /// One rung of the conversation. The server decides what it means.
    func narrow(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let service else { return }
        loadTask?.cancel()
        state = .loading
        let steps = history
        let current = filters
        loadTask = Task { [weak self] in
            do {
                let narrowing = try await service.filesNarrow(q: trimmed, filters: current,
                                                              history: steps)
                guard !Task.isCancelled, let self else { return }
                self.apply(narrowing, utterance: trimmed)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.state = .failed((error as? APIError)?.localizedDescription
                                     ?? error.localizedDescription)
            }
        }
    }

    private func apply(_ narrowing: FilesNarrowing, utterance: String) {
        // The history records what was ASKED and what was in force when it was
        // asked, which is the pair the server needs to read the next rung
        // against. Appending the answer's own filters instead would lose the
        // step where the user started.
        history.append(FileNarrowStep(q: utterance, filters: filters))
        filters = narrowing.filters
        appliedQuery = narrowing.query.isEmpty ? nil : narrowing.query
        query = narrowing.query
        explanation = narrowing.explanation.isEmpty ? nil : narrowing.explanation
        page = 1
        adopt(narrowing.result, replacing: true)
    }

    // MARK: - Arriving from an answer

    /// A `files` payload from a chat or voice turn. Replaces whatever the
    /// browser was showing, because that is what "show me the Robolabs
    /// spreadsheets" asks for.
    func apply(payload: FilesPayload) {
        filters = payload.filters
        appliedQuery = payload.query.isEmpty ? nil : payload.query
        query = payload.query
        history = []
        explanation = nil
        sortWithoutReloading(payload.query.isEmpty ? .mtimeDesc : .relevance)
        page = 1
        load(replacing: true)
    }

    /// Takes a payload left in the route latch, if there is one. Called both
    /// when the browser appears and when the notification fires, and `take`
    /// hands it over once - so an already-open browser and a just-opened one
    /// behave identically.
    func takePendingRoute() {
        guard let payload = FilesRoute.take() else { return }
        apply(payload: payload)
    }

    // MARK: - Cache

    private struct Cached: Codable {
        let hits: [FileHit]
        let total: Int
        let facets: FileFacets
        let filters: FileFilters
        let query: String?
        let sortRaw: String

        var sort: FileSort { FileSort(rawValue: sortRaw) ?? .mtimeDesc }
    }

    private func save() {
        guard let cacheRoot else { return }
        // Only the first page is kept. The cache exists to put something on
        // screen in the frame the tile opens, and forty rows do that as well
        // as four hundred would.
        TileCache.save(Cached(hits: Array(hits.prefix(pageSize)), total: total,
                              facets: facets, filters: filters,
                              query: appliedQuery, sortRaw: sort.rawValue),
                       kind: Self.cacheKind, for: cacheRoot)
    }
}
