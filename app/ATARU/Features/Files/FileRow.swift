import SwiftUI

/// One file in the browser.
///
/// The name is the headline, because that is what he is scanning for. Under it
/// goes either the snippet (when searching) or where the file lives (when
/// browsing) - never both, because a row that says everything says nothing.
struct FileRow: View {
    let hit: FileHit
    let service: ATARUService

    var body: some View {
        ATCard {
            HStack(alignment: .top, spacing: Theme.Space.s) {
                FileThumbnail(hit: hit, service: service)

                VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Space.xs) {
                        Text(hit.name)
                            .font(.ataruBody())
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: Theme.Space.xxs)
                        if hit.location.isAway {
                            // Not decoration. This file's bytes are on the NAS
                            // and there is nothing to open on this host - the
                            // badge is the warning that the tap will not show
                            // a document. See FileViewerScreen.
                            ATPill(text: "NAS", tone: Theme.amber)
                        }
                    }

                    if let snippet = hit.snippet, !snippet.isEmpty {
                        Text(snippet)
                            .font(.ataruCaption())
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack(spacing: Theme.Space.xs) {
                        Text(hit.placeLine)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let mtime = hit.mtime {
                            Text("·")
                            Text(RelativeTime.compact(for: mtime))
                        }
                        if let size = hit.size, size > 0 {
                            Text("·")
                            Text(MetricFormatter.bytes(size))
                        }
                        Spacer(minLength: 0)
                        if !hit.ext.isEmpty {
                            Text(hit.ext.uppercased())
                                .font(.ataruMono(10))
                        }
                    }
                    .font(.ataruCaption())
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.top, Theme.Space.xxs)
                }
            }
            .padding(Theme.Space.s)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(.isButton)
    }

    /// One sentence rather than six fragments - same rule as `DocumentCard`.
    private var accessibilityText: String {
        var parts = [hit.name, hit.kind.rowTitle, hit.placeLine]
        if let mtime = hit.mtime {
            parts.append("modified \(RelativeTime.string(for: mtime))")
        }
        if let size = hit.size, size > 0 { parts.append(MetricFormatter.bytes(size)) }
        if hit.location.isAway { parts.append("stored on the NAS, not on this host") }
        if let snippet = hit.snippet, !snippet.isEmpty { parts.append(snippet) }
        return parts.joined(separator: ", ")
    }
}

/// The look of a filter chip, with no behaviour attached.
///
/// Split out from the button because one entry on the umbrella rail is a
/// NAVIGATION LINK rather than a filter - the vault records are a different
/// index - and wrapping a Button in a NavigationLink stacks two controls on
/// one target, of which the wrong one usually wins.
struct FacetChipLabel: View {
    let label: String
    var count: Int?
    var symbol: String?
    var isSelected: Bool = false

    var body: some View {
        HStack(spacing: Theme.Space.xxs) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .medium))
            }
            Text(label)
                .font(.ataruCaption())
                .lineLimit(1)
            if let count {
                Text("\(count)")
                    .font(.ataruMono(11))
                    .foregroundStyle(isSelected ? Theme.onAccent.opacity(0.65)
                                                : Theme.textTertiary)
            }
        }
        .foregroundStyle(isSelected ? Theme.onAccent : Theme.textSecondary)
        .padding(.horizontal, Theme.Space.s)
        .frame(height: 30)
        .background { Capsule().fill(isSelected ? Theme.cyan : Color.clear) }
        .overlay {
            Capsule().strokeBorder(isSelected ? .clear : Theme.border, lineWidth: 1)
        }
        .contentShape(Capsule())
        .hitTarget()
    }
}

/// A filter chip with a count, used for every rail on the Files screen.
struct FileFacetChip: View {
    let label: String
    let count: Int?
    let symbol: String?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            FacetChipLabel(label: label, count: count, symbol: symbol,
                           isSelected: isSelected)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(count.map { "\(label), \($0) files" } ?? label)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}

/// An applied filter, with the way to take it off.
struct AppliedFilterChip: View {
    let chip: FileFilterChip
    let remove: () -> Void

    var body: some View {
        Button(action: remove) {
            HStack(spacing: Theme.Space.xxs) {
                Image(systemName: chip.symbol)
                    .font(.system(size: 10, weight: .medium))
                Text(chip.label)
                    .font(.ataruCaption())
                    .lineLimit(1)
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .opacity(0.75)
            }
            .foregroundStyle(Theme.onAccent)
            .padding(.horizontal, Theme.Space.s)
            .frame(height: 30)
            .background { Capsule().fill(Theme.cyan) }
            .contentShape(Capsule())
            .hitTarget()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(chip.label) filter")
        .accessibilityHint("Double tap to remove this filter.")
    }
}

/// The narrowing affordance. A field, because a sentence typed with a thumb
/// is still faster than six taps - and the docked orb speaks into exactly the
/// same path for the times it is not.
///
/// ## Why it owns its own text
///
/// It used to write into a `@State` on `FilesScreen`, and SwiftUI re-runs the
/// body that OWNS the state. So every character typed here rebuilt the whole
/// browser: three chip rails, the applied-filter row, the count line and the
/// list's `ForEach`. Keeping the text down here means a keystroke redraws a
/// field, and the utterance only leaves when it is submitted.
struct FilesNarrowField: View {
    let submit: (String) -> Void

    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            Image(systemName: "sparkles")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.cyanSubdued)
            TextField("Narrow: just the 2025 spreadsheets", text: $text)
                // Named, like the Ask composer's field, so the UI suite can
                // reach it without depending on a placeholder string.
                .accessibilityIdentifier("narrow-field")
                .font(.ataruCaption())
                .foregroundStyle(Theme.textPrimary)
                .focused($isFocused)
                .submitLabel(.go)
                .onSubmit(send)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            if !text.isEmpty {
                Button(action: send) {
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

    private func send() {
        let utterance = text
        text = ""
        isFocused = false
        submit(utterance)
    }
}

/// Umbrella first, then pods when the vault is in play, then kinds and years.
///
/// One horizontal line each rather than a wrapping block: three wrapping
/// rails would push the first file most of a screen down, and these are
/// browsed by sweeping rather than read all at once.
///
/// ## Why it is `Equatable` and its own view
///
/// The rails were a computed property of `FilesScreen`, so they were rebuilt
/// every single time anything on the view model published - a page arriving,
/// a "load more" starting, a cached-at label ticking, a character typed into
/// the narrow field. Measured on the fixture that was one full rebuild of all
/// three rails per screen body pass, and the screen body ran fifteen times in
/// a six-swipe sweep.
///
/// The facets and the filters are the ONLY things a rail draws from, and both
/// are value types that compare cheaply, so `.equatable()` lets SwiftUI skip
/// the rebuild outright when neither has moved. The closures are deliberately
/// left out of the comparison: they capture the view model, which is a
/// reference and does not change identity for the life of the screen.
struct FileFacetRails: View, Equatable {
    let facets: FileFacets
    let filters: FileFilters
    let toggleUmbrella: (String) -> Void
    let togglePod: (String) -> Void
    let toggleKind: (FileKind) -> Void
    let toggleYear: (Int) -> Void

    static func == (lhs: FileFacetRails, rhs: FileFacetRails) -> Bool {
        lhs.facets == rhs.facets && lhs.filters == rhs.filters
    }

    var body: some View {
        let umbrellas = facets.orderedUmbrellas
        let pods = facets.orderedPods
        let kinds = facets.orderedKinds
        let years = facets.orderedYears

        VStack(alignment: .leading, spacing: Theme.Space.xs) {
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
                                      isSelected: filters.umbrellas.contains(entry.name)) {
                            Haptics.fire(.selection)
                            toggleUmbrella(entry.name)
                        }
                    }
                }
            }

            if !pods.isEmpty {
                rail {
                    ForEach(pods, id: \.name) { entry in
                        FileFacetChip(label: entry.name.capitalized, count: entry.count,
                                      symbol: nil,
                                      isSelected: filters.pods.contains(entry.name)) {
                            Haptics.fire(.selection)
                            togglePod(entry.name)
                        }
                    }
                }
            }

            if !kinds.isEmpty || !years.isEmpty {
                rail {
                    ForEach(kinds, id: \.kind) { entry in
                        FileFacetChip(label: entry.kind.title, count: entry.count,
                                      symbol: entry.kind.symbol,
                                      isSelected: filters.kinds.contains(entry.kind)) {
                            Haptics.fire(.selection)
                            toggleKind(entry.kind)
                        }
                    }
                    ForEach(years.prefix(6), id: \.year) { entry in
                        FileFacetChip(label: "\(entry.year)", count: entry.count,
                                      symbol: "calendar",
                                      isSelected: filters.year == entry.year) {
                            Haptics.fire(.selection)
                            toggleYear(entry.year)
                        }
                    }
                }
            }
        }
    }

    /// A rail scrolls SIDEWAYS AND NOTHING ELSE.
    ///
    /// `.scrollBounceBehavior(.basedOnSize)` is the half that matters: a rail
    /// whose chips fit has nothing to scroll, and a scroll view with nothing
    /// to scroll still rubber-bands - which is a vertical-looking gesture
    /// starting on a horizontal control, and was half of why a downward sweep
    /// here felt like it was pulling the page.
    private func rail<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Space.xxs) { content() }
                .padding(.horizontal, Theme.Space.screen)
        }
        .scrollClipDisabled()
    }
}
