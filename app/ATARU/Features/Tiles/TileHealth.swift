import SwiftUI

// MARK: - Health dots

/// Live up/down per launcher key, from the production launcher's manifest
/// (`GET <ATARU_TILES_URL>/api/launcher`).
///
/// The destination set is the native `HomeTile` enum - the manifest only
/// supplies the dots. An unreachable launcher therefore degrades to a screen
/// without a status dot, never to a missing or unroutable destination.
///
/// Read by the screens that show a machine's state: `ServiceCardScreen` and
/// `RemoteScreen`.
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
            ATARUAuth.stamp(&request)
            let (data, _) = try await URLSession.cacheless.data(for: request)
            let manifest = try JSONDecoder().decode(Manifest.self, from: data)
            var next: [String: Bool] = [:]
            for row in manifest.tiles where row.probed == true {
                next[row.key] = row.up ?? false
            }
            upByKey = next
        } catch {
            // Dots just don't render; nothing else is affected.
        }
    }
}
