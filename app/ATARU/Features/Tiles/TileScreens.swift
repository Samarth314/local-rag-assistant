import SwiftUI

// MARK: - Backend resolution

/// Where a tile's data comes from, decided by the server the app points at.
///
/// The rule is the user's: if Settings points at a production server, tiles
/// show REAL data from the production view apps; if it points at the dev box
/// (any host containing "dev."), tiles show the dev twins' fixture data.
/// One switch, every tile follows it.
struct TileBackend {
    let isDev: Bool

    init(baseURLString: String) {
        isDev = baseURLString.lowercased().contains("dev.")
    }

    private static let prodDomain = "ataru.aryasasikumar.com"
    private static let devRoot = "https://dev.ataru.aryasasikumar.com"

    /// The JSON API root for a surface (no trailing slash).
    func apiRoot(_ tile: HomeTile) -> URL? {
        let raw: String?
        if isDev {
            switch tile {
            case .finance:    raw = "\(Self.devRoot)/finance"
            case .health:     raw = "\(Self.devRoot)/health"
            case .home:       raw = "\(Self.devRoot)/home"
            case .status:     raw = "\(Self.devRoot)/status"
            case .journal:    raw = "\(Self.devRoot)/journal"
            case .workspaces: raw = "\(Self.devRoot)/workspaces"
            default:          raw = nil
            }
        } else {
            switch tile {
            case .finance:    raw = "https://\(Self.prodDomain)/finance"
            case .health:     raw = "https://\(Self.prodDomain)/health"
            case .home:       raw = "https://home.\(Self.prodDomain)"
            case .status:     raw = "https://dash.\(Self.prodDomain)"
            case .journal:    raw = "https://journal.\(Self.prodDomain)"
            case .workspaces: raw = "https://\(Self.prodDomain)/workspaces"
            default:          raw = nil
            }
        }
        return raw.flatMap(URL.init(string:))
    }

    @MainActor
    static func current(from state: AppState) -> TileBackend {
        TileBackend(baseURLString: state.configuration.baseURLString)
    }
}

/// Shared fetch helper for the tile screens: plain tailnet GET/POST, JSON.
enum TileFetch {
    static func get<T: Decodable>(_ type: T.Type, _ url: URL) async throws -> T {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode(type, from: data)
    }

    @discardableResult
    static func post<T: Decodable, Body: Encodable>(
        _ type: T.Type, _ url: URL, body: Body) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode(type, from: data)
    }
}

// MARK: - Host

/// Dispatches a tile to its native screen.
///
/// A layer in the root stack rather than a sheet, so the launcher can stay
/// above it: a sheet outranks every layer the root view owns, and a launcher
/// the fan cannot be seen over is a launcher that does not work on that page.
/// The opaque backdrop is what makes it a screen rather than an overlay —
/// nothing behind shows through, and nothing behind takes a touch.
struct TileScreenHost: View {
    let tile: HomeTile
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            screen
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(action: onClose) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(Theme.textTertiary)
                        }
                        .accessibilityLabel("Close")
                    }
                }
        }
        .background(Ataru.Palette.bg.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var screen: some View {
        switch tile {
        case .plan:       PlanView()
        case .finance:    FinanceScreen()
        case .health:     HealthScreen()
        case .home:       HomeScreen()
        case .status:     StatusScreen()
        case .journal:    JournalScreen()
        case .workspaces: WorkspacesScreen()
        default:          ServiceCardScreen(tile: tile)
        }
    }
}

// MARK: - Service card (third-party surfaces)

/// A native face for the third-party services (Jellyfin, Navidrome,
/// Vaultwarden, Portainer, ntfy, the remote hub, the canvas): what it is and
/// whether it's up. These are full products of their own - the honest native
/// treatment is status, not a half-reimplementation.
struct ServiceCardScreen: View {
    let tile: HomeTile
    @StateObject private var health = TileHealthModel()

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Space.m) {
                ATCard {
                    VStack(spacing: Theme.Space.m) {
                        Image(systemName: tile.symbol)
                            .font(.system(size: 42, weight: .ultraLight))
                            .foregroundStyle(Theme.cyan)
                        Text(tile.kind)
                            .font(.ataruLabel())
                            .foregroundStyle(Theme.textPrimary)
                        if let up = health.upByKey[tile.launcherKey] {
                            Label(up ? "Online" : "Offline",
                                  systemImage: up ? "checkmark.circle" : "xmark.circle")
                                .font(.ataruCaption())
                                .foregroundStyle(up ? Theme.green : Theme.red)
                        }
                        Text(blurb)
                            .font(.ataruCaption())
                            .foregroundStyle(Theme.textSecondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(Theme.Space.l)
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(Theme.Space.screen)
        }
        .ataruBackdrop()
        .navigationTitle(tile.title == "Spaces" ? "Workspaces" : tile.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await health.refresh() }
    }

    private var blurb: String {
        switch tile {
        case .media:         return "Jellyfin runs on the mini. Use the Jellyfin app or a browser on the tailnet for playback - a video server deserves its own player."
        case .music:         return "Navidrome on the mini. Any Subsonic-compatible player on the tailnet connects to it."
        case .passwords:     return "Vaultwarden on the mini. Pair it with the Bitwarden app pointed at the tailnet URL."
        case .remote:        return "noVNC screens for the mini, Orin and NAS - a desktop-sized surface, best used from a desktop."
        case .whiteboard:    return "The PenEcho AI canvas - handwriting first, so it lives best on the iPad or a desktop."
        default:             return ""
        }
    }
}
