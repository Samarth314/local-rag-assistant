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
            let (data, response) = try await URLSession.cacheless.data(for: request)
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

// MARK: - Last known content

/// The last payload each tile screen saw, on disk, so a cold open draws
/// something in the first frame instead of a blank page.
///
/// ## Why every screen, and not just Home
///
/// "When I open a tile I haven't opened in a long time, it's slow." It was:
/// nothing renders until the fetch returns, and these fetches cross the tailnet
/// to the mini and gather a whole dashboard - Home's own call is given a 25
/// second timeout for exactly that reason. Home already solved this by keeping
/// its last payload and reconciling; the pattern was simply never generalised,
/// so five other screens still opened blank and waited.
///
/// A cold open now draws the last known content immediately and quietly
/// replaces it when the network answers. What was true five minutes ago is
/// enormously more useful than nothing, and the screens that could mislead say
/// so: a page still showing cache when the refresh FAILS puts up a "showing
/// cached data from…" banner, which is the only case where the age matters.
///
/// First ever open with nothing cached goes straight to the content skeleton on
/// the backdrop - never a differently coloured pane.
enum TileCache {

    private struct Envelope<Payload: Codable>: Codable {
        let payload: Payload
        let savedAt: Date
    }

    /// Derived from the backend URL by substitution, NOT by `hashValue` -
    /// String hashing is seeded per process, so a hashed filename would miss
    /// its own cache on the next launch, which is the only launch that matters.
    ///
    /// Keyed by the URL, so pointing the app at the dev twin cannot serve
    /// production's numbers out of a cache, or the reverse.
    private static func fileURL(kind: String, root: URL) -> URL? {
        guard let dir = FileManager.default.urls(for: .cachesDirectory,
                                                 in: .userDomainMask).first else { return nil }
        let slug = root.absoluteString.replacingOccurrences(
            of: "[^A-Za-z0-9]", with: "-", options: .regularExpression)
        return dir.appending(path: "\(kind)-\(slug).json")
    }

    static func load<Payload: Codable>(_ type: Payload.Type, kind: String,
                                       for root: URL?) -> (payload: Payload, savedAt: Date)? {
        guard let root, let url = fileURL(kind: kind, root: root),
              let data = try? Data(contentsOf: url),
              let envelope = try? JSONDecoder().decode(Envelope<Payload>.self, from: data)
        else { return nil }
        return (envelope.payload, envelope.savedAt)
    }

    static func save<Payload: Codable>(_ payload: Payload, kind: String, for root: URL) {
        guard let url = fileURL(kind: kind, root: root),
              let data = try? JSONEncoder().encode(
                Envelope(payload: payload, savedAt: Date()))
        else { return }
        try? data.write(to: url, options: .atomic)
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
                // Kept as the affordance - it is what says the page can be
                // pulled away at all - and deliberately STATIC. It used to
                // brighten past the release threshold, which meant it read
                // `pull` and so re-evaluated on every touch-moved event; it
                // sits in a `safeAreaInset`, so every one of those events
                // re-measured the inset and re-laid out the whole page
                // underneath it. That was half the jitter. What the threshold
                // feels like is now carried by the page dissolving under the
                // thumb and by one haptic, which is better feedback anyway.
                .safeAreaInset(edge: .top, spacing: 0) { grabBar }
        }
        // The gesture, the offset and the dissolve all live in a MODIFIER, and
        // that is load-bearing rather than tidy - see TileDismissal.
        .tileDismissal(onClose: onClose)
        .background(AtaruBackdrop(surface: "tile.\(tile.rawValue)"))
        .preferredColorScheme(.dark)
    }

    private var grabBar: some View {
        // A generous strip around a small mark: 28pt of target for a 4pt bar,
        // because the thing you have to hit should be bigger than the thing
        // you can see.
        Capsule()
            .fill(Theme.textTertiary.opacity(0.45))
            .frame(width: 38, height: 4)
            .frame(maxWidth: .infinity)
            .frame(height: 28)
            .contentShape(Rectangle())
            .accessibilityLabel("Close")
            .accessibilityHint("Drag down anywhere on the page to close it.")
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
        // Both of these used to live somewhere else and be the exception.
        // Documents was a second ROOT screen, reached by swapping what the app
        // was showing, so it had no host chrome and nothing to swipe away.
        // Settings was a gear in the Ask navigation bar - a permanent control
        // on the app's front page for something touched about twice a year.
        // They are ordinary tiles now, and every destination behaves the same.
        case .documents:  DocumentsView()
        case .settings:   SettingsView()
        default:          ServiceCardScreen(tile: tile)
        }
    }
}

// MARK: - Pulling a page away

/// Drag the page down to close it: the gesture, the tracking, and the dissolve.
///
/// ## Why a ViewModifier and not just more state on the host
///
/// "It jitters while I pull down." It did, and the state was in the wrong
/// place. `pull` lived on `TileScreenHost`, and `TileScreenHost.body` is what
/// builds `screen` - so every touch-moved event invalidated the host's body and
/// SwiftUI re-evaluated the entire tile page, sixty times a second, while the
/// finger was down. On a light page that is invisible. On Finance or Workspaces
/// it is exactly the stutter he reported.
///
/// A ViewModifier fixes it structurally. `body(content:)` receives the already
/// built subtree as an opaque value, so state changing HERE re-runs this
/// twenty-line body and does not touch the page at all. The offset, the scale
/// and the opacity are layer properties the compositor animates without asking
/// SwiftUI to lay anything out again.
///
/// The other two contributors, both gone: the grab bar read `pull` from inside
/// a `safeAreaInset` (re-measuring the inset, and therefore the page, per
/// event), and `pull` carried an implicit `.animation`, so every frame started
/// a new spring toward a value the finger had already left behind - motion
/// chasing motion, which is what "jitter" usually is.
///
/// ## What it feels like
///
/// The offset tracks the thumb exactly, with no animation on it while the
/// finger is down. As the page travels it shrinks slightly and fades - the
/// dissolve he asked for, driven by DISTANCE rather than by a timer, so the
/// page visibly comes apart in proportion to the gesture and letting go early
/// puts it straight back. Past the threshold it is committed: a light impact
/// when the drag is claimed, one success tick at the moment crossing the
/// threshold would close it, and then the page dissolves out rather than
/// snapping back to zero and vanishing - which is what made the old exit feel
/// abrupt, because the page jumped back UP to its origin at the same instant
/// it disappeared.
/// Rects where a downward drag already means something to the control under it.
///
/// Same idea as `PressExclusionKey`, deliberately a separate key: what a long
/// press must keep off is not the same set as what a drag must keep off. A
/// stepper wants vertical drags; the orb does not care about them.
struct DismissExclusionKey: PreferenceKey {
    static let defaultValue: [CGRect] = []
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) {
        value.append(contentsOf: nextValue())
    }
}

extension View {
    /// Marks this view as a control that owns its own drags, so the page
    /// dismissal never starts from a finger that landed on it.
    ///
    /// Opt-in per control rather than inferred. The alternative was hit-testing
    /// the window and looking for a `UIControl`, which answers correctly for a
    /// TextField, unreliably for a Toggle and never for a SwiftUI Button - a
    /// rule that is right two thirds of the time is worse than one that is
    /// written down.
    func dismissExclusion() -> some View {
        background(
            GeometryReader { geo in
                Color.clear.preference(key: DismissExclusionKey.self,
                                       value: [geo.frame(in: .global)])
            }
        )
    }
}

/// Drag the page down to close it: the gesture, the tracking, and the dissolve.
///
/// ## Why a ViewModifier and not just more state on the host
///
/// "It jitters while I pull down." It did, and the state was in the wrong
/// place. `pull` lived on `TileScreenHost`, and `TileScreenHost.body` is what
/// builds `screen` - so every touch-moved event invalidated the host's body and
/// SwiftUI re-evaluated the entire tile page, sixty times a second, while the
/// finger was down. On a light page that is invisible. On Finance or Workspaces
/// it is exactly the stutter he reported.
///
/// A ViewModifier fixes it structurally. `body(content:)` receives the already
/// built subtree as an opaque value, so state changing HERE re-runs this
/// twenty-line body and does not touch the page at all. The offset, the scale
/// and the opacity are layer properties the compositor animates without asking
/// SwiftUI to lay anything out again.
///
/// ## Why it takes a deliberate pull, and did not used to
///
/// "Most of the tiles in the app don't involve scrolling but some do (like docs
/// and settings). I've swiped out of the tile on accident when I didn't mean
/// to." Structural, and obvious in hindsight: the claim rule was "the content
/// is at its scroll top", and on a page with nothing to scroll that is true
/// forever. Every downward wiggle was a dismissal.
///
/// Four things raise the bar without making the gesture indirect:
///
/// * **A dead zone.** Nothing happens at all - no movement, no haptic, no
///   scroll lock - until the finger has travelled `activateAt` downward. Past
///   it the page picks up from zero rather than jumping, so the gesture still
///   feels like dragging the page and not like tripping a switch.
/// * **Vertical dominance**, at 2:1 rather than the old 1:1. A drag that is
///   only just more vertical than horizontal is a wander, not an intent.
/// * **Controls keep their own drags.** A finger that lands on a toggle, a
///   picker or a text field never starts a dismissal - see `dismissExclusion`.
/// * **A longer pull on pages that do not scroll**, where there is no scroll
///   gesture to disambiguate against and the extra caution costs nothing. On
///   Docs or Settings the at-top rule is already doing that work, so those
///   keep the shorter throw.
struct TileDismissal: ViewModifier {
    let onClose: () -> Void

    /// How far the page has been pulled, with the dead zone already
    /// subtracted. Never animated while a finger is down.
    @State private var pull: CGFloat = 0
    /// Whether the hosted page's ScrollView is at its top. True until told
    /// otherwise: a page with no ScrollView never reports, and that is a real
    /// answer rather than a missing one - it is trivially at its top.
    ///
    /// Note what this canNOT do on its own, which is the whole reason for the
    /// dead zone: on a page with nothing to scroll it is true forever, so it
    /// admits every downward wiggle. It is a handoff rule, not a protection.
    @State private var atTop = true
    /// Controls that own their own drags, in global coordinates.
    @State private var exclusions: [CGRect] = []
    /// True once a drag has been claimed as a dismissal.
    @State private var claimed = false
    /// Set when a drag has been examined and rejected, so the decision is made
    /// once per gesture instead of re-litigated on every event - otherwise a
    /// finger that started on a toggle could still claim later by wandering.
    @State private var refused = false
    /// Whether letting go right now would close the page. Tracked so the
    /// haptic fires once per crossing rather than on every event past it.
    @State private var wouldClose = false

    /// Vestibular motion is the part of this that is optional. Under Reduce
    /// Motion the page still follows the thumb - that is direct manipulation,
    /// not decoration, and taking it away would make the gesture unreadable -
    /// but it does not scale as it goes, which is the part that reads as
    /// movement through depth.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Travel before the gesture is anything at all. Between 25 and 30 was the
    /// brief; 28 is a deliberate wiggle and nowhere near a scroll flick.
    private let activateAt: CGFloat = 28
    /// Past this, releasing closes. ONE number, on every page.
    ///
    /// It was 150 on pages with nothing to scroll and 110 on pages that
    /// scroll, on the theory that the extra caution cost nothing where there
    /// was no competing gesture. It cost plenty: "swipe feels better on docs
    /// but it's bad on the finance page." Docs has a long list and therefore
    /// scrolls; Finance is a ScrollView whose three cards FIT, so it reported
    /// itself as not scrolling and got the heavy throw - as did Health,
    /// Status, Journal, Workspaces, Plan and most of the app, since most tile
    /// pages fit on a screen. Worse, `progress` divides by this, so those
    /// pages also dissolved a quarter more slowly for the same travel: the
    /// page moved under the thumb and looked less committed while doing it.
    ///
    /// What actually prevents an accidental dismissal is the dead zone, the
    /// 2:1 dominance test and the control exclusions - all of which stay. The
    /// extra 40pt was buying nothing but a heavy feel.
    private let releaseAt: CGFloat = 110
    /// A drag starting inside this band from the top is treated as a handle
    /// drag and skips the at-top rule, the way a sheet's grabber does. It
    /// covers the navigation bar and the grab bar under it, neither of which
    /// is scrolling content.
    ///
    /// MEASURED, NOT ASSUMED. It was a flat 132, which is the right answer in
    /// portrait on this phone and only there: 132 is the 59pt safe-area top
    /// plus a 44pt navigation bar plus the 28pt grab bar, and the first of
    /// those three goes to ZERO in landscape when the island moves to the
    /// side. So on a phone lying down, 132 of a 393pt screen - a third of it,
    /// most of which is ordinary content - skipped the at-top rule, and a
    /// downward drag there dismissed the page instead of scrolling it.
    private var handleBand: CGFloat { ActiveWindow.topInset + 73 }

    func body(content: Content) -> some View {
        content
            // The page's own scroll position and whether it scrolls at all,
            // read from out here. This is what the iOS 18 floor was raised for.
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y <= geometry.contentInsets.top + 0.5
            } action: { _, top in
                atTop = top
            }
            .onPreferenceChange(DismissExclusionKey.self) { exclusions = $0 }
            // Handing the gesture over cleanly rather than letting two things
            // move at once: without this the ScrollView rubber-bands downward
            // under the same finger that is already moving the whole page.
            .scrollDisabled(claimed)
            // Distance-driven, not time-driven. Cheap layer properties only -
            // a blur here would be a full-screen render pass per frame, which
            // is a jitter of its own; the blur belongs in the removal
            // transition, where it runs once.
            .scaleEffect(reduceMotion ? 1 : 1 - 0.05 * progress, anchor: .top)
            .opacity(Double(1 - 0.4 * progress))
            .offset(y: pull)
            .simultaneousGesture(drag)
            // No visible escape, so there has to be an invisible one: this is
            // VoiceOver's two-finger scrub and Switch Control's escape.
            .accessibilityAction(.escape) { close() }
    }

    /// 0 at rest, 1 at the point where letting go closes the page.
    private var progress: CGFloat {
        min(1, max(0, pull) / releaseAt)
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .global)
            .onChanged { value in
                if !claimed {
                    guard !refused else { return }
                    // Below the dead zone nothing has happened yet, and
                    // nothing is decided yet either - a gesture is only judged
                    // once it is long enough to have a direction worth reading.
                    guard value.translation.height >= activateAt else { return }
                    guard canClaim(value) else {
                        refused = true
                        return
                    }
                    claimed = true
                    Haptics.fire(.tap)
                }
                // Raw. No withAnimation, no implicit animation on `pull`: the
                // page has to be exactly where the thumb put it. The dead zone
                // is subtracted so the page starts from where the finger was
                // when it was claimed, rather than jumping 28pt.
                let travel = value.translation.height - activateAt
                pull = travel > 0 ? travel : travel / 6

                // One tick when crossing into "letting go closes it", and one
                // more only if he pulls back out and in again. The lower reset
                // point is hysteresis - a thumb resting on the threshold would
                // otherwise buzz continuously.
                if !wouldClose, pull > releaseAt {
                    wouldClose = true
                    Haptics.fire(.success)
                } else if wouldClose, pull < releaseAt * 0.85 {
                    wouldClose = false
                }
            }
            .onEnded { value in
                refused = false
                guard claimed else { return }
                claimed = false
                wouldClose = false
                // A flick counts as much as a distance, so a fast gesture is
                // not punished for being fast.
                let projected = value.translation.height - activateAt
                    + value.predictedEndTranslation.height / 3
                if projected > releaseAt {
                    close()
                } else {
                    withAnimation(Theme.spring) { pull = 0 }
                }
            }
    }

    /// Whether this drag is allowed to become a dismissal.
    private func canClaim(_ value: DragGesture.Value) -> Bool {
        // Downward, and decisively so. 2:1 rather than the old "more vertical
        // than horizontal", which admitted a 46-degree wander.
        guard value.translation.height > 0,
              value.translation.height > abs(value.translation.width) * 2
        else { return false }
        // A control that takes drags of its own keeps this one.
        if exclusions.contains(where: { $0.contains(value.startLocation) }) {
            return false
        }
        // The grab bar and the navigation bar are handles: they are not
        // scrolling content, so they close the page however far down it has
        // been read - which is what a sheet's grabber does.
        if value.startLocation.y < handleBand { return true }
        // Anywhere else: the content has to be at its top, which is the
        // standard sheet rule. On a page that does not scroll this is always
        // true - the dead zone and the dominance test above are what stand
        // between a wiggle and a dismissal there.
        return atTop
    }

    /// Commit. The page keeps travelling as it dissolves rather than snapping
    /// back to its origin first - `pull` is deliberately NOT reset, because
    /// this view is about to be removed and its state goes with it.
    private func close() {
        withAnimation(Theme.quick) { pull += 40 }
        onClose()
    }
}

extension View {
    func tileDismissal(onClose: @escaping () -> Void) -> some View {
        modifier(TileDismissal(onClose: onClose))
    }
}

/// Coming apart rather than being switched off.
///
/// A plain opacity fade holds every edge crisp the whole way to invisible,
/// which reads as the page being cut. Softening and receding slightly as it
/// goes reads as it dissolving into the backdrop, which is what a page being
/// put away is doing. The counterpart of the launcher's own `dissolve` - same
/// idea, one motion vocabulary - but it recedes instead of growing, because
/// this one is being pushed away rather than let go of.
private struct TileDissolve: ViewModifier {
    /// 0 is the page as drawn, 1 is gone.
    let amount: Double

    func body(content: Content) -> some View {
        content
            .blur(radius: amount * 7)
            .opacity(1 - amount)
            .scaleEffect(1 - amount * 0.06, anchor: .top)
    }
}

extension AnyTransition {
    static var tileDissolve: AnyTransition {
        .modifier(active: TileDissolve(amount: 1), identity: TileDissolve(amount: 0))
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
