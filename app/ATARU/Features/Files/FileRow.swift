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
