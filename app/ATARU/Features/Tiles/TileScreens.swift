import SwiftUI

// MARK: - Backend resolution

/// Where a tile's data comes from, decided by the server the app points at.
///
/// The rule is the user's: if Settings points at a production server, tiles
/// show REAL data from the production view apps; if it points at the dev twin,
/// tiles show its fixture data. One switch, every tile follows it.
struct TileBackend {
    let isDev: Bool

    init(baseURLString: String) {
        isDev = Self.isDevBackend(baseURLString)
    }

    private static let prodDomain = "ataru.aryasasikumar.com"
    /// The dev twin, by host. Exactly this host and nothing else.
    static let devHost = "dev.ataru.aryasasikumar.com"
    private static let devRoot = "https://\(devHost)"

    /// Whether a configured base URL points at the dev twin.
    ///
    /// HOST EQUALITY, never a substring. This used to be
    /// `baseURLString.lowercased().contains("dev.")`, which is true of any URL
    /// with those four characters anywhere in it: `mydev.company.com`,
    /// `ataru.aryasasikumar.com.dev.cdn.net`, a path like `/dev.html`, a query
    /// like `?flag=dev.x`. The failure is silent and it is the bad direction -
    /// a production URL that trips it serves every tile from the dev twin's
    /// FIXTURES while looking exactly like production, so Finance and Health
    /// would show invented numbers with nothing on screen saying so.
    static func isDevBackend(_ baseURLString: String) -> Bool {
        let trimmed = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        // The Settings field does not insist on a scheme, and URLComponents
        // reads a bare "host/path" as a path with no host at all - which would
        // make every scheme-less entry look like production.
        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let host = URLComponents(string: candidate)?.host?.lowercased() else {
            return false
        }
        // A fully-qualified name may carry a trailing root dot.
        let normalized = host.hasSuffix(".") ? String(host.dropLast()) : host
        return normalized == devHost
    }

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
        // The same backdrop every other surface in the app paints, not the
        // flat `Palette.bg` this used to use. #090A0C against a gradient
        // running #15181D to #060708 is a visible shade difference wherever
        // the two meet - and during a transition, where both are on screen at
        // once, it was the whole screen. Matching it means the background is
        // one continuous thing no matter which layer is drawing it.
        .background(Ataru.backdrop.ignoresSafeArea())
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
        case .morning:    MorningCallScreen()
        case .remote:     RemoteScreen()
        default:          ServiceCardScreen(tile: tile)
        }
    }
}

// MARK: - Service card (third-party surfaces)

/// A native face for the third-party services - Jellyfin, Navidrome,
/// Vaultwarden and the PenEcho canvas: what it is and whether it's up. These
/// are full products of their own, and the honest native treatment is status
/// rather than a half-reimplementation.
///
/// Portainer and ntfy used to be listed here and are not tiles at all any
/// more (see HomeTile: Docker and Notify were removed outright). The remote
/// hub was the fifth card until it earned a real page - RemoteScreen - and
/// TileScreenHost routes `.remote` there now, so nothing reaches this screen
/// asking about it.
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
        // Only reached when Swiftfin is NOT installed - RootView.open(tile:)
        // hands `.media` straight to the app otherwise and never presents this
        // screen. So the text is about the missing client, not about Jellyfin.
        case .media:         return "Jellyfin runs on the mini, and Swiftfin isn't installed on this phone. Install Swiftfin and this tile opens it directly; until then, use a browser on the tailnet."
        case .music:         return "Navidrome on the mini. Any Subsonic-compatible player on the tailnet connects to it."
        case .passwords:     return "Vaultwarden on the mini. Pair it with the Bitwarden app pointed at the tailnet URL."
        case .whiteboard:    return "The PenEcho AI canvas - handwriting first, so it lives best on the iPad or a desktop."
        default:             return ""
        }
    }
}
