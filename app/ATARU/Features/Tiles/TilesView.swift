import SwiftUI

// MARK: - Health dots

/// Live up/down per launcher key, from the production launcher's manifest
/// (`GET <ATARU_TILES_URL>/api/launcher`). The grid itself is the native
/// `HomeTile` set - the manifest only supplies the dots, so an unreachable
/// launcher degrades to a grid without dots, never to missing tiles.
@MainActor
final class TileHealthModel: ObservableObject {
    @Published var upByKey: [String: Bool] = [:]

    private struct Manifest: Decodable {
        struct Row: Decodable {
            let key: String
            let probed: Bool?
            let up: Bool?
        }
        let tiles: [Row]
    }

    static var manifestURL: URL? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "ATARUTilesURL") as? String,
              !raw.trimmingCharacters(in: .whitespaces).isEmpty,
              let base = URL(string: raw) else { return nil }
        return base.appending(path: "api/launcher")
    }

    func refresh() async {
        guard let url = Self.manifestURL else { return }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 8
            let (data, _) = try await URLSession.shared.data(for: request)
            let manifest = try JSONDecoder().decode(Manifest.self, from: data)
            var next: [String: Bool] = [:]
            for row in manifest.tiles where row.probed == true {
                next[row.key] = row.up ?? false
            }
            upByKey = next
        } catch {
            // Dots just don't render; the grid is unaffected.
        }
    }
}

// MARK: - Screen

/// Everything ATARU can do, one grid - the launcher wall, in the pocket.
/// Every tile opens a native screen; the radial dial launches the same set.
struct TilesView: View {
    @StateObject private var health = TileHealthModel()

    let onOpen: (HomeTile) -> Void

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 220),
                                    spacing: Theme.Space.s)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: Theme.Space.s) {
                    ForEach(HomeTile.allCases) { tile in
                        Button {
                            onOpen(tile)
                        } label: {
                            TileCell(tile: tile,
                                     up: health.upByKey[tile.launcherKey])
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, Theme.Space.screen)
                .padding(.top, Theme.Space.s)
                .padding(.bottom, Theme.Space.xl)
            }
            .ataruBackdrop()
            .navigationTitle("Tiles")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable { await health.refresh() }
        }
        .task { await health.refresh() }
    }
}

// MARK: - Cell

/// One tile: glyph, name, quiet subtitle, live dot. Frosted panel on the
/// dark backdrop - the launcher wall's language at phone size.
struct TileCell: View {
    let tile: HomeTile
    let up: Bool?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack {
                Image(systemName: tile.symbol)
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(Theme.cyan)
                Spacer(minLength: 0)
                if let up {
                    Circle()
                        .fill(up ? Theme.green : Theme.red)
                        .frame(width: 7, height: 7)
                        .opacity(0.9)
                        .accessibilityLabel(up ? "online" : "offline")
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 2) {
                Text(tile.title == "Spaces" ? "Workspaces" : tile.title)
                    .font(.ataruLabel())
                    .foregroundStyle(Theme.textPrimary)
                Text(tile.kind)
                    .font(.ataruCaption())
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, minHeight: 108, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .fill(Theme.surface)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(Theme.border, lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card,
                                       style: .continuous))
    }
}

#Preview {
    TilesView(onOpen: { _ in })
        .environmentObject(AppState())
}
