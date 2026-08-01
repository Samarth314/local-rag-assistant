import SwiftUI

/// One row in the library.
///
/// Shows the title, where it lives and when it was last touched. The full
/// vault path is deliberately reduced to its parent directory: the whole path
/// is long, personal, and rarely what the user is scanning for.
struct DocumentCard: View {
    let document: IndexedDocument

    var body: some View {
        ATCard {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.xs) {
                    Text(document.title)
                        .font(.ataruBody())
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: Theme.Space.xs)
                    // One accent, per the kit. Tinting these per category read
                    // as semantic status — amber as "warning", green as "ok" —
                    // when it only ever meant "filed under", and three hues
                    // down a list compete with the orb for attention.
                    ATPill(text: document.category.title)
                }

                Text(document.excerpt.isEmpty ? document.subtitleFallback : document.excerpt)
                    .font(.ataruCaption())
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: Theme.Space.s) {
                    Label(parentDirectory, systemImage: "folder")
                        .lineLimit(1)
                        .truncationMode(.head)
                    if let modified = document.modifiedAt {
                        Text(RelativeTime.compact(for: modified))
                    }
                    Spacer(minLength: 0)
                    if !document.fileType.isEmpty {
                        Text(document.fileType.uppercased())
                            .font(.ataruMono(10))
                    }
                }
                .font(.ataruCaption())
                .foregroundStyle(Theme.textTertiary)
            }
            .padding(Theme.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(.isButton)
    }

    private var parentDirectory: String {
        let parent = URL(fileURLWithPath: document.path).deletingLastPathComponent().lastPathComponent
        return parent.isEmpty ? "vault" : parent
    }

    /// One sentence rather than six fragments, so VoiceOver reads a card as a
    /// sentence instead of a list of disconnected values.
    private var accessibilityText: String {
        var parts = [document.title, document.category.title]
        if let modified = document.modifiedAt {
            parts.append("modified \(RelativeTime.string(for: modified))")
        }
        if !document.excerpt.isEmpty { parts.append(document.excerpt) }
        return parts.joined(separator: ", ")
    }
}

#Preview {
    VStack {
        DocumentCard(document: DemoFixtures.documents()[0])
        DocumentCard(document: DemoFixtures.documents()[2])
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .ataruBackdrop()
}
