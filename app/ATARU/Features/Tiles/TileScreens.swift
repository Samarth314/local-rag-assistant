import OSLog
import SwiftUI

/// Logging for the tile surfaces. Their failures are all network-shaped and
/// none of them are visible after the fact - this is what turns "it said it
/// couldn't reach the server" into which call, and why.
///
///     log stream --device --predicate 'subsystem == "com.ataru.client"'
///
let tileLog = Logger(subsystem: "com.ataru.client", category: "tiles")

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

/// Why a tile's fetch failed - kept apart, because they are not the same
/// problem and only one of them is about the network.
///
/// THE BUG THIS EXISTS TO FIX. Every one of these used to arrive at the same
/// `catch { failed = true }` and print "Couldn't reach this surface - check
/// Tailscale and the server in Settings." That is a claim about reachability,
/// and nothing in the old code ever tested reachability: `get` did not look at
/// the status code at all, so a 502 from the proxy, a 200 carrying an HTML
/// error page, and a genuinely dead tailnet were indistinguishable. Hence a
/// Home page that declared itself unreachable while its own toggles - same
/// host, same session - were switching the lights fine.
enum TileFetchError: LocalizedError, Equatable {
    /// Nothing answered. The ONLY case that justifies telling someone to go
    /// and look at Tailscale.
    case unreachable
    case timedOut(seconds: Int)
    /// The server answered, and the answer was a refusal.
    case status(Int)
    /// The server answered with something this page cannot read.
    case undecodable

    var errorDescription: String? {
        switch self {
        case .unreachable:
            return ScreenState.unreachable
        case .timedOut(let seconds):
            return "The server didn't answer within \(seconds)s. It may still be gathering this."
        case .status(let code):
            return "The server answered with HTTP \(code)."
        case .undecodable:
            return "The server answered with something this page couldn't read."
        }
    }

    /// One line, for when there is already content on screen. Losing a refresh
    /// is not the same event as having nothing to show, and it must not be
    /// dressed as one.
    var refreshNote: String {
        switch self {
        case .unreachable:  return "Couldn't refresh - no answer from the server."
        case .timedOut:     return "Refresh timed out."
        case .status(let code): return "Couldn't refresh - the server said HTTP \(code)."
        case .undecodable:  return "Couldn't refresh - unreadable answer."
        }
    }

    static func from(_ error: Error, timeout: TimeInterval) -> TileFetchError {
        if let already = error as? TileFetchError { return already }
        let ns = error as NSError
        guard ns.domain == NSURLErrorDomain else {
            // A decoding error is not a network error, and saying so is the
            // whole point of this type.
            return .undecodable
        }
        switch ns.code {
        case NSURLErrorTimedOut: return .timedOut(seconds: Int(timeout))
        default: return .unreachable
        }
    }
}

/// Shared fetch helper for the tile screens: plain tailnet GET/POST, JSON.
enum TileFetch {
    static let defaultTimeout: TimeInterval = 10

    static func get<T: Decodable>(_ type: T.Type, _ url: URL,
                                  timeout: TimeInterval = defaultTimeout) async throws -> T {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        // These went out bare until now. See ATARUAuth.
        ATARUAuth.stamp(&request)
        return try await run(type, request, timeout: timeout)
    }

    @discardableResult
    static func post<T: Decodable, Body: Encodable>(
        _ type: T.Type, _ url: URL, body: Body,
        timeout: TimeInterval = defaultTimeout) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        ATARUAuth.stamp(&request)
        return try await run(type, request, timeout: timeout)
    }

    private static func run<T: Decodable>(_ type: T.Type, _ request: URLRequest,
                                          timeout: TimeInterval) async throws -> T {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            // Checked at last. Without this a proxy's 502 error page reached
            // JSONDecoder, failed there, and was reported as a network fault.
            if let http = response as? HTTPURLResponse,
               !(200...299).contains(http.statusCode) {
                throw TileFetchError.status(http.statusCode)
            }
            do {
                return try JSONDecoder().decode(type, from: data)
            } catch {
                throw TileFetchError.undecodable
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let classified = TileFetchError.from(error, timeout: timeout)
            // The path only, never the body: these responses are vault content.
            tileLog.error("""
                \(request.httpMethod ?? "GET", privacy: .public) \
                \(request.url?.path ?? "?", privacy: .public) failed: \
                \(classified.errorDescription ?? "", privacy: .public)
                """)
            throw classified
        }
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

    /// How far the page has been pulled down, and the distance past which
    /// letting go means "close" rather than "never mind".
    @State private var pull: CGFloat = 0
    private let releaseAt: CGFloat = 110

    var body: some View {
        NavigationStack {
            screen
                // The grab bar sits between the navigation bar and the
                // content, where a sheet's would be, and it OWNS the gesture
                // rather than sharing it.
                //
                // Sharing was the obvious design and it does not work here.
                // The standard sheet rule - claim the drag only while the
                // content is at scroll top - needs the host to know a child
                // ScrollView's offset, and every one of these pages owns its
                // own ScrollView. Reading that offset from out here needs
                // onScrollGeometryChange, which is iOS 18; this app targets
                // 17. A simultaneous gesture without it would scroll the page
                // AND drag the sheet on the same finger.
                //
                // So the handle is the whole of the gesture's surface. It
                // cannot fight scrolling because it is not on the scrolling
                // part, and it is visible, which is the other half of making
                // a gesture usable.
                .safeAreaInset(edge: .top, spacing: 0) { grabBar }
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
        // Only the content moves. The backdrop behind this is the same
        // gradient, so the page slides over a background that stays perfectly
        // still - no edge, no shade change, nothing sweeping.
        .offset(y: pull)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: pull)
    }

    /// Drag down to put the page away.
    private var grabBar: some View {
        // A generous strip around a small mark: 28pt of target for a 4pt bar,
        // because the thing you have to hit should be bigger than the thing
        // you can see.
        Capsule()
            .fill(Theme.textTertiary.opacity(pull > releaseAt ? 0.9 : 0.45))
            .frame(width: 38, height: 4)
            .frame(maxWidth: .infinity)
            .frame(height: 28)
            .contentShape(Rectangle())
            .background(Color.clear)
            .gesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { value in
                        // Downward only, and rubber-banded upward so pulling
                        // the wrong way reads as resistance rather than as
                        // nothing happening.
                        pull = value.translation.height > 0
                            ? value.translation.height
                            : value.translation.height / 6
                    }
                    .onEnded { value in
                        // A flick counts as much as a distance: releasing at
                        // speed near the threshold should still close, or a
                        // fast gesture gets punished for being fast.
                        let projected = value.translation.height
                            + value.predictedEndTranslation.height / 3
                        if projected > releaseAt {
                            Haptics.fire(.tap)
                            onClose()
                            // Reset behind the dismissal, so reopening the
                            // page does not start it half way down the screen.
                            pull = 0
                        } else {
                            pull = 0
                        }
                    }
            )
            .accessibilityLabel("Close")
            .accessibilityHint("Drag down, or use the close button.")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { onClose() }
    }

    @ViewBuilder
    private var screen: some View {
        switch tile {
        case .plan:       PlanView()
        case .notes:      NotesScreen()
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
