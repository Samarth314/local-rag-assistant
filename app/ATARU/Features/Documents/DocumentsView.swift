import SwiftUI

/// The document library: everything ATARU has indexed.
struct DocumentsView: View {
    @EnvironmentObject private var state: AppState
    @StateObject private var model: DocumentsViewModel

    init() {
        _model = StateObject(wrappedValue: DocumentsViewModel(service: DemoATARUService()))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Ataru.backdrop.ignoresSafeArea()
                content
            }
            .navigationTitle("Library")
            .navigationBarTitleDisplayMode(.large)
            .searchable(text: $model.query, prompt: "Search titles and paths")
            .toolbar {
                // Without this the Library is a dead end for anyone who
                // cannot press-and-sweep. See TileDestinationsMenu.
                ToolbarItem(placement: .topBarLeading) { TileDestinationsMenu() }
                ToolbarItem(placement: .topBarTrailing) { sortMenu }
            }
            .refreshable { await model.refresh() }
            .navigationDestination(for: IndexedDocument.self) { document in
                DocumentDetailView(document: document)
            }
        }
        .task(id: ObjectIdentifier(state.service)) {
            model.update(service: state.service)
            if model.state == .idle { model.load() }
        }
    }

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 0) {
            FreshnessBanner(state: state.freshness)
                .padding(.horizontal, Theme.Space.screen)
                .padding(.bottom, Theme.Space.xs)

            categoryFilter

            switch model.state {
            case .idle, .loading where model.page.documents.isEmpty:
                skeletonList
            case .failed(let message):
                ATStateView(symbol: "wifi.slash", title: "Couldn't load your library",
                            message: message, tone: Theme.amber) { model.load(force: true) }
                Spacer()
            default:
                if model.isFilteredToNothing {
                    ATStateView(symbol: "line.3.horizontal.decrease.circle",
                                title: "No matches",
                                message: "Nothing in \(model.category.title) matches “\(model.query)”. Try another category or clear the search.")
                    Spacer()
                } else if model.isEmpty {
                    ATStateView(symbol: "tray",
                                title: "Nothing indexed yet",
                                message: "Run the indexer on your vault and documents will appear here.") {
                        model.load(force: true)
                    }
                    Spacer()
                } else {
                    list
                }
            }
        }
    }

    /// Filters wrap onto a second line rather than scrolling off the edge — a
    /// category the user cannot see is one they will not use, and a scroll view
    /// gives no hint that more exist.
    ///
    /// Empty categories are hidden, so a flat vault shows one chip instead of
    /// six, five of which do nothing.
    private var categoryFilter: some View {
        FlowLayout(spacing: Theme.Space.xs, lineSpacing: Theme.Space.xs) {
            ForEach(visibleCategories) { category in
                CategoryChip(
                    category: category,
                    count: model.count(for: category),
                    isSelected: model.category == category
                ) {
                    model.category = category
                    Haptics.fire(.selection)
                }
            }
        }
        .padding(.horizontal, Theme.Space.screen)
        // A clear pause between the filters and the list below them.
        .padding(.bottom, Theme.Space.m)
    }

    private var countLabel: String {
        let shown = model.visibleDocuments.count
        let total = model.page.indexedTotal
        return shown == total ? "\(total) documents" : "\(shown) of \(total)"
    }

    private var visibleCategories: [DocumentCategory] {
        DocumentCategory.allCases.filter {
            // Always keep All, and whatever is selected, so the row never drops
            // the chip the user just tapped out from under them.
            $0 == .all || $0 == model.category || model.count(for: $0) > 0
        }
    }

    private var list: some View {
        ScrollView {
            // Gutter-sized gaps between cards. The tighter list read as a
            // solid wall of panels; at this spacing each document floats on
            // the backdrop instead, which is most of what "less cramped"
            // means on this screen.
            LazyVStack(spacing: Theme.Space.m) {
                HStack {
                    // "11 of 11" is noise; the fraction only means something
                    // once a filter is actually hiding things.
                    SectionLabel(text: countLabel)
                    Spacer()
                }
                .padding(.horizontal, Theme.Space.screen)
                .padding(.bottom, Theme.Space.xxs)

                ForEach(model.visibleDocuments) { document in
                    NavigationLink(value: document) {
                        DocumentCard(document: document)
                    }
                    .buttonStyle(.atPress)
                    .padding(.horizontal, Theme.Space.screen)
                }
            }
            .padding(.bottom, Theme.Space.l)
        }
    }

    private var skeletonList: some View {
        VStack(spacing: Theme.Space.s) {
            ForEach(0..<5, id: \.self) { _ in
                ATCard {
                    VStack(alignment: .leading, spacing: Theme.Space.xs) {
                        ATSkeleton(height: 16, width: 190)
                        ATSkeleton(height: 12)
                        ATSkeleton(height: 12, width: 240)
                    }
                    .padding(Theme.Space.m)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, Theme.Space.screen)
            }
            Spacer()
        }
        .accessibilityLabel("Loading documents")
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort", selection: $model.sort) {
                ForEach(DocumentSort.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .accessibilityLabel("Sort documents")
    }
}

/// Filter chip: name and count, no icon.
///
/// The icon was doing no work — six categories with six glyphs is decoration
/// competing with the accent, and the words are already short. Dropping it also
/// narrows every chip, which is what lets the set fit two lines instead of
/// three.
private struct CategoryChip: View {
    let category: DocumentCategory
    let count: Int
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.xxs) {
                Text(category.title)
                    .font(.ataruCaption())
                Text("\(count)")
                    .font(.ataruMono(11))
                    .foregroundStyle(isSelected ? Theme.onAccent.opacity(0.65) : Theme.textTertiary)
            }
            .foregroundStyle(isSelected ? Theme.onAccent : Theme.textSecondary)
            .padding(.horizontal, Theme.Space.s)
            .frame(height: 30)
            .background {
                Capsule().fill(isSelected ? Theme.cyan : Color.clear)
            }
            .overlay {
                Capsule().strokeBorder(isSelected ? .clear : Theme.border, lineWidth: 1)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        // The chip is terse; VoiceOver gets the unabbreviated version.
        .accessibilityLabel("\(category.title), \(count) documents")
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}

#Preview {
    DocumentsView().environmentObject(AppState())
}
