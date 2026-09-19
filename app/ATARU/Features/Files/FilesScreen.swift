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

    /// The narrow field. Separate from the search field on purpose: search is
    /// "find me things called X", narrowing is "and only the 2025 ones", and
    /// typing the second into the first would throw the first away.
    @State private var narrowText = ""
    @FocusState private var narrowFocused: Bool
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
        .refreshable { model.reload() }
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
            narrowField

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

            rails
        }
        .padding(.bottom, Theme.Space.xs)
    }

    /// The narrowing affordance. A field, because a sentence typed with a
    /// thumb is still faster than six taps - and the docked orb speaks into
    /// exactly the same path for the times it is not.
    private var narrowField: some View {
        HStack(spacing: Theme.Space.xs) {
            Image(systemName: "sparkles")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.cyanSubdued)
            TextField("Narrow: just the 2025 spreadsheets", text: $narrowText)
                // Named, like the Ask composer's field, so the UI suite can
                // reach it without depending on a placeholder string.
                .accessibilityIdentifier("narrow-field")
                .font(.ataruCaption())
                .foregroundStyle(Theme.textPrimary)
                .focused($narrowFocused)
                .submitLabel(.go)
                .onSubmit(submitNarrow)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            if !narrowText.isEmpty {
                Button(action: submitNarrow) {
                    Image(systemName: "arrow.forward.circle.fill")
                        .foregroundStyle(Theme.cyan)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Narrow the list")
            }
        }
        .padding(.horizontal, Theme.Space.s)
        .frame(height: 36)
        .background {
            Capsule().fill(Theme.surfaceElevated)
                .overlay { Capsule().strokeBorder(Theme.border, lineWidth: 1) }
        }
        .padding(.horizontal, Theme.Space.screen)
    }

    /// Umbrella first, then pods when the vault is in play, then kinds.
    ///
    /// One horizontal line each rather than a wrapping block: three wrapping
    /// rails would push the first file most of a screen down, and these are
    /// browsed by sweeping rather than read all at once.
    @ViewBuilder
    private var rails: some View {
        let umbrellas = model.facets.orderedUmbrellas
        let pods = model.facets.orderedPods
        let kinds = model.facets.orderedKinds
        let years = model.facets.orderedYears

        if !umbrellas.isEmpty {
            rail {
                // A destination, not a filter: the vault records are a
                // different index with different ids, so this pushes the
                // library rather than narrowing the list.
                NavigationLink(value: FilesDestination.vaultRecords) {
                    FacetChipLabel(label: "Vault records", symbol: "tray.full")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Vault records")
                .accessibilityHint("Opens the vault document library.")
                ForEach(umbrellas, id: \.name) { entry in
                    FileFacetChip(label: entry.name, count: entry.count,
                                  symbol: nil,
                                  isSelected: model.filters.umbrellas.contains(entry.name)) {
                        model.toggle(umbrella: entry.name)
                        Haptics.fire(.selection)
                    }
                }
            }
        }

        if !pods.isEmpty {
            rail {
                ForEach(pods, id: \.name) { entry in
                    FileFacetChip(label: entry.name.capitalized, count: entry.count,
                                  symbol: nil,
                                  isSelected: model.filters.pods.contains(entry.name)) {
                        model.toggle(pod: entry.name)
                        Haptics.fire(.selection)
                    }
                }
            }
        }

        if !kinds.isEmpty || !years.isEmpty {
            rail {
                ForEach(kinds, id: \.kind) { entry in
                    FileFacetChip(label: entry.kind.title, count: entry.count,
                                  symbol: entry.kind.symbol,
                                  isSelected: model.filters.kinds.contains(entry.kind)) {
                        model.toggle(kind: entry.kind)
                        Haptics.fire(.selection)
                    }
                }
                ForEach(years.prefix(6), id: \.year) { entry in
                    FileFacetChip(label: "\(entry.year)", count: entry.count,
                                  symbol: "calendar",
                                  isSelected: model.filters.year == entry.year) {
                        model.toggle(year: entry.year)
                        Haptics.fire(.selection)
                    }
                }
            }
        }
    }

    private func rail<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Space.xxs) { content() }
                .padding(.horizontal, Theme.Space.screen)
        }
        .scrollClipDisabled()
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

    private func submitNarrow() {
        let text = narrowText
        narrowText = ""
        narrowFocused = false
        model.narrow(text)
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
