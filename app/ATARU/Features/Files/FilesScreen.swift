import SwiftUI

/// Files: everything in `~/Projects`, browsable from the phone.
///
/// ## Two indexes, one tile
///
/// The vault library (`/documents`) and the projects index (`/api/files`) are
/// separate stores with separate ids, and merging them into one list would
/// mean a client-side sort over two paginated sources that disagree about
/// relevance - which is a worse list than either. So the projects index is the
/// tile, and the vault records are ONE named source inside it, reached by the
/// "Vault records" chip. The tile is called Files because that is what a
/// person is looking for when they open it.
///
/// ## Why the rails are built from facets
///
/// Counting the rows on screen would relabel every chip on "load more" and be
/// wrong until the last page arrived. The server counts over the whole match
/// set; this screen draws what it is told.
struct FilesScreen: View {
    @EnvironmentObject private var state: AppState
    @StateObject private var model = FilesViewModel()
    @StateObject private var voice = VoiceViewModel(service: DemoATARUService())

    @State private var caption: String?
    @State private var captionTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            AtaruBackdrop(surface: "files")
            content
        }
        .navigationTitle("Files")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $model.query, prompt: "Search all your files")
        .onSubmit(of: .search) { model.submitQuery() }
        .onChange(of: model.query) { _, _ in model.queryChanged() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { sortMenu }
        }
        // NO `.refreshable`, ON PURPOSE.
        //
        // "The horizontal pill rails can be pulled down and that triggers a
        // reload of the page." `.refreshable` is not attached to a scroll
        // view, it is published into the ENVIRONMENT, and every scroll view
        // underneath picks it up - which on this page means the three chip
        // rails as well as the list. A rail is 30pt tall and scrolls
        // sideways, so a thumb sweeping across it is always partly vertical,
        // and the page reloaded under him while he was choosing a filter.
        //
        // Scoping it to the list was the other option and buys nothing here:
        // this page already reloads when it opens, when the connection comes
        // back, on every chip, on every narrowing and on every search. There
        // was nothing a pull could fetch that something else was not already
        // fetching.
        .navigationDestination(for: FileHit.self) { hit in
            FileViewerScreen(hit: hit, service: state.service)
        }
        .navigationDestination(for: FilesDestination.self) { destination in
            switch destination {
            case .vaultRecords: DocumentsView()
            }
        }
        // The docked orb, and whatever it last said.
        .overlay(alignment: .bottomTrailing) { dock }
        .sheet(item: $voice.presentedDocument) { document in
            DocumentRefViewer(document: document, service: state.service)
                .interactiveDismissDisabled(true)
        }
        .task(id: state.serviceGeneration) {
            model.configure(service: state.service,
                            cacheRoot: state.isDemo ? nil : state.configuration.baseURL)
            voice.update(service: state.service)
            await model.restore()
            // A payload may already be waiting: the tile was opened BY an
            // answer, and the notification fired before this view existed.
            model.takePendingRoute()
            if model.state == .idle { model.reload() }
        }
        // A browser that failed during an outage reloads itself when the
        // tunnel comes back, rather than waiting to be closed and reopened.
        .task(id: state.onlineGeneration) {
            guard state.onlineGeneration > 0 else { return }
            model.reload()
        }
        // And the warm case: an answer arriving while the browser is open.
        .onReceive(NotificationCenter.default.publisher(for: .ataruFilesRoute)) { _ in
            model.takePendingRoute()
        }
    }

    // MARK: - Body

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 0) {
            header
            switch model.state {
            case .idle, .loading where model.hits.isEmpty:
                skeleton
            case .failed(let message) where model.hits.isEmpty:
                ATStateView(symbol: "wifi.slash", title: "Couldn't load your files",
                            message: message, tone: Theme.amber) { model.reload() }
                Spacer()
            default:
                if model.isEmpty {
                    ATStateView(
                        symbol: model.isFiltered ? "line.3.horizontal.decrease.circle" : "tray",
                        title: model.isFiltered ? "No matches" : "Nothing indexed yet",
                        message: model.isFiltered
                            ? "Nothing matches these filters. Take one off, or clear them all."
                            : "Run the files indexer on your projects folder and they will appear here.",
                        tone: Theme.textSecondary,
                        retry: model.isFiltered ? nil : { model.reload() })
                    Spacer()
                } else {
                    list
                }
            }
        }
    }

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            // Its own view, holding its own text. It used to write into a
            // `@State` on this screen, which meant every keystroke rebuilt
            // the whole page - the three rails and the list included - to
            // redraw one field.
            FilesNarrowField { model.narrow($0) }

            if !model.filters.chips.isEmpty {
                FlowLayout(spacing: Theme.Space.xxs, lineSpacing: Theme.Space.xxs) {
                    ForEach(model.filters.chips) { chip in
                        AppliedFilterChip(chip: chip) {
                            model.remove(chip)
                            Haptics.fire(.selection)
                        }
                    }
                    Button("Clear") { model.clearFilters() }
                        .font(.ataruCaption())
                        .foregroundStyle(Theme.textTertiary)
                        .frame(height: 30)
                        .hitTarget()
                }
                .padding(.horizontal, Theme.Space.screen)
            }

            if let explanation = model.explanation {
                // The SERVER'S sentence, verbatim. See FilesNarrowing.
                Label(explanation, systemImage: "sparkles")
                    .font(.ataruCaption())
                    .foregroundStyle(Theme.cyan)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Theme.Space.screen)
            }

            if let message = model.refreshFailure {
                Text(message)
                    .font(.ataruCaption())
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, Theme.Space.screen)
            }

            FileFacetRails(facets: model.facets, filters: model.filters,
                           toggleUmbrella: { model.toggle(umbrella: $0) },
                           togglePod: { model.toggle(pod: $0) },
                           toggleKind: { model.toggle(kind: $0) },
                           toggleYear: { model.toggle(year: $0) })
                .equatable()
        }
        .padding(.bottom, Theme.Space.xs)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: Theme.Space.s) {
                HStack {
                    SectionLabel(text: model.countLabel)
                    Spacer()
                    if let cachedAt = model.cachedAt {
                        Text("cached \(RelativeTime.compact(for: cachedAt))")
                            .font(.ataruCaption())
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                .padding(.horizontal, Theme.Space.screen)

                ForEach(model.hits) { hit in
                    NavigationLink(value: hit) {
                        FileRow(hit: hit, service: state.service)
                    }
                    .buttonStyle(.atPress)
                    .padding(.horizontal, Theme.Space.screen)
                }

                if model.hasMore {
                    Button {
                        model.loadMore()
                    } label: {
                        HStack(spacing: Theme.Space.xs) {
                            if model.isLoadingMore { ProgressView().tint(Theme.cyan) }
                            Text(model.isLoadingMore ? "Loading" : "Load more")
                                .font(.ataruCaption())
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.cyan)
                    .padding(.horizontal, Theme.Space.screen)
                    // Auto-paging as well as a button: the button is what
                    // makes it discoverable and reachable for anyone the
                    // scroll never reaches.
                    .onAppear { model.loadMore() }
                }
            }
            // Clears the docked orb, so the last row is never under it.
            .padding(.bottom, 96)
        }
    }

    private var skeleton: some View {
        VStack(spacing: Theme.Space.s) {
            ForEach(0..<6, id: \.self) { _ in
                ATCard {
                    HStack(spacing: Theme.Space.s) {
                        ATSkeleton(height: 46, width: 46)
                        VStack(alignment: .leading, spacing: Theme.Space.xs) {
                            ATSkeleton(height: 14, width: 200)
                            ATSkeleton(height: 11, width: 150)
                        }
                        Spacer()
                    }
                    .padding(Theme.Space.s)
                }
                .padding(.horizontal, Theme.Space.screen)
            }
            Spacer()
        }
        .accessibilityLabel("Loading files")
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort", selection: $model.sort) {
                ForEach(FileSort.options(searching: model.isSearching)) { option in
                    Text(option.title).tag(option)
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .accessibilityLabel("Sort files")
    }

    // MARK: - The dock

    @ViewBuilder
    private var dock: some View {
        VStack(alignment: .trailing, spacing: Theme.Space.xs) {
            if let caption {
                DockedOrbCaption(text: caption) { self.caption = nil }
                    .frame(maxWidth: 260, alignment: .trailing)
            }
            // A document opens through the model's own `presentedDocument`
            // (the sheet above binds to it) and a listing arrives through the
            // route latch, so what is left for the page to do is caption the
            // plain answers.
            DockedOrb(model: voice) { answer in show(caption: answer) }
        }
        .padding(.trailing, Theme.Space.m)
        .padding(.bottom, Theme.Space.m)
    }

    private func show(caption text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        caption = trimmed
        captionTask?.cancel()
        captionTask = Task {
            try? await Task.sleep(for: .seconds(9))
            guard !Task.isCancelled else { return }
            caption = nil
        }
    }

}

/// The one non-file destination this screen pushes.
enum FilesDestination: Hashable {
    case vaultRecords
}

#Preview {
    NavigationStack {
        FilesScreen().environmentObject(AppState())
    }
}
