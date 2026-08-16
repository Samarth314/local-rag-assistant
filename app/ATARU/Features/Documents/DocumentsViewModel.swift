import Foundation
import SwiftUI

/// Drives the document library.
///
/// Search is debounced and filtering happens locally on the loaded page, so
/// typing feels immediate; the server is only re-queried when the category
/// changes or the user explicitly refreshes. On a vault of a few hundred
/// documents that is the difference between a responsive list and one that
/// stutters on every keystroke.
@MainActor
final class DocumentsViewModel: ObservableObject {

    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    @Published private(set) var state: LoadState = .idle
    @Published private(set) var page: DocumentLibraryPage = .empty
    @Published var query: String = ""
    @Published var category: DocumentCategory = .all
    @Published var sort: DocumentSort = .ingestDate

    private var service: ATARUService
    private var loadTask: Task<Void, Never>?

    init(service: ATARUService) {
        self.service = service
    }

    func update(service: ATARUService) {
        guard self.service !== service else { return }
        // The old server's request is cancelled, not merely forgotten. It
        // captured the previous service and would have published ITS documents
        // into the new session - the library would have been showing one
        // backend's files under the other's name.
        loadTask?.cancel()
        loadTask = nil
        self.service = service
        page = .empty
        state = .idle
    }

    /// What the list actually renders: the loaded page, filtered and sorted
    /// on device so the UI never waits on a round trip to reorder.
    var visibleDocuments: [IndexedDocument] {
        DocumentQuery.apply(page.documents, query: query, category: category, sort: sort)
    }

    var isEmpty: Bool { state == .loaded && visibleDocuments.isEmpty }

    /// What went wrong last, when there is still a library on screen.
    ///
    /// A failed refresh over a loaded library is a lost round trip, not an
    /// empty library - the page still holds every document it fetched. It used
    /// to render the error view instead, so one flaky refresh blanked a
    /// working page.
    var refreshFailure: String? {
        guard case .failed(let message) = state, !page.documents.isEmpty else { return nil }
        return message
    }

    /// True when the vault has documents but the current filter hides them
    /// all — a different message from "nothing is indexed".
    var isFilteredToNothing: Bool {
        isEmpty && page.indexedTotal > 0
    }

    func count(for category: DocumentCategory) -> Int {
        category == .all ? page.indexedTotal : (page.categoryCounts[category] ?? 0)
    }

    func load(force: Bool = false) {
        if state == .loading && !force { return }
        loadTask?.cancel()
        state = .loading
        loadTask = Task { [service] in
            do {
                // The whole library is fetched once and filtered locally; the
                // server-side `q` is left unset so typing doesn't refetch.
                let result = try await service.documents(query: nil, category: .all)
                guard !Task.isCancelled else { return }
                page = result
                state = .loaded
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                state = .failed((error as? APIError)?.localizedDescription
                                ?? error.localizedDescription)
            }
        }
    }

    func refresh() async {
        load(force: true)
        await loadTask?.value
    }
}
