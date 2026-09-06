import Combine
import Foundation
import SwiftUI

/// App-wide state: which backend is in use, and whether it answers.
///
/// Owns the single `ATARUService` every feature talks to, so switching between
/// Demo and Live is one assignment here rather than a flag threaded through
/// every view model.
@MainActor
final class AppState: ObservableObject {

    @Published private(set) var service: ATARUService
    @Published private(set) var connection: ConnectionState = .unknown
    /// True while the app is answering from bundled sample files rather than a
    /// server.
    ///
    /// Not a mode any more - a CONSEQUENCE. There is no Demo/Live switch; there
    /// is an address, and this is what it means for the address to be missing
    /// or malformed. Kept because the freshness banner has to say so: an app
    /// quietly answering from fixtures while looking exactly like the real
    /// thing is the one outcome worth a permanent banner.
    @Published private(set) var isDemo = true
    /// Bumped every time `service` is replaced.
    ///
    /// Views used to key their `.task(id:)` on `ObjectIdentifier(state.service)`,
    /// which is the OBJECT'S ADDRESS. Replacing a service releases the old one
    /// and the allocator is free to hand the new one the same address — and a
    /// same-address rebuild produces an identical id, so the task does not
    /// re-run and every consumer keeps the old wiring. That is a coin flip
    /// sitting under "save the token and push re-registers", so nothing keys
    /// on identity any more.
    @Published private(set) var serviceGeneration = 0

    /// Bumped on every unreachable → reachable transition, and never
    /// otherwise.
    ///
    /// THE ONE SIGNAL EVERY DATA SCREEN LISTENS TO. Before this, each tile
    /// screen fetched once in its own `.task` and then sat there: turning
    /// Tailscale on with Finance already open left the page showing "couldn't
    /// refresh" until it was closed and reopened, because nothing in the app
    /// told it the world had changed. Keying `.task(id:)` on this makes the
    /// reload structural - a screen that is on screen when the tunnel comes up
    /// reloads itself, and one that is not simply loads fresh when it opens.
    ///
    /// A counter rather than a boolean on purpose: two outages in one session
    /// have to be two distinct ids, or the second reconnection is a no-op.
    /// Monotonic, so it can never be mistaken for a level.
    @Published private(set) var onlineGeneration = 0

    /// Whether the OS believes this device has any usable network path.
    ///
    /// Separate from `connection` because they fail differently and the user
    /// can only act on one of them. No path is airplane mode; a path with no
    /// server is, on this app's topology, almost always Tailscale being off.
    @Published private(set) var hasNetworkPath = true

    /// When the app last got a real answer out of the server. Drives the
    /// "last synced" half of the offline banner; nil until the first success
    /// of the process.
    @Published private(set) var lastConnectedAt: Date?

    /// "I'm up", shared by every surface that offers it.
    ///
    /// ONE MODEL, DELIBERATELY. It used to be a `@StateObject` in VoiceView
    /// AND another in CallSessionView, which is two independent copies of one
    /// fact: tapping the button on the call screen left the Ask page's banner
    /// sitting there offering to confirm a call that had already been
    /// confirmed, and the call screen's own copy never called `refresh()` at
    /// all, so it drew its button whenever the call was a morning call
    /// regardless of what the server said. Owning it here is what makes a tap
    /// anywhere retract it everywhere, in the same run loop.
    let morning = MorningConfirmModel()

    @Published var configuration: AppConfiguration {
        didSet {
            guard configuration != oldValue else { return }
            persist()
            // Suppressed only while `apply` is staging both fields, which
            // rebuilds once itself.
            guard !isStaging else { return }
            rebuildService()
        }
    }

    /// True while `apply` is setting the token and the address together.
    private var isStaging = false

    private let defaults: UserDefaults
    private let tokenStore: TokenStoring
    /// One key, defined on the configuration itself - the App Intents path
    /// reads the same blob without any of this object being alive.
    private static let configurationKey = AppConfiguration.defaultsKey

    /// The launch/foreground probe, so a second one cancels the first rather
    /// than racing it to publish a verdict.
    private var probe: Task<Void, Never>?

    /// Re-publishes the shared morning model's changes as this object's own.
    ///
    /// A nested `ObservableObject` does NOT notify the parent's observers, so
    /// without this every view reading `state.morning` would draw the value it
    /// happened to see first and never update - which is the same class of
    /// silent staleness the two-copies bug was. Forwarding here means any view
    /// already holding `@EnvironmentObject var state: AppState` sees it, and
    /// nothing has to add a second environment object it can crash for
    /// forgetting.
    private var morningObserver: AnyCancellable?
    private let reachability = Reachability()

    /// How long to wait before each retry, in seconds. Five attempts over
    /// about fifteen seconds, which comfortably outlasts a tailnet coming up.
    ///
    /// The ladder is the fix for the launch bug: the FIRST answer is not the
    /// verdict any more. Nothing is published as a failure until every rung
    /// has been tried, so a negative from second one - the common case on a
    /// cold launch, before the Tailscale path exists - costs a retry rather
    /// than a banner that then sticks.
    private static let retryDelays: [Double] = [1, 2, 4, 8]

    /// What happens AFTER the verdict, which is the other half of the same
    /// bug.
    ///
    /// The ladder above only ever decided whether to publish a failure. Once
    /// it had, the app went completely quiet: nothing probed again until the
    /// next foreground or an OS path change, so switching Tailscale on with
    /// the app open in front of you changed nothing at all - the phone was
    /// reachable and the app went on saying it was not, indefinitely, because
    /// no path event fires when a VPN tunnel comes up inside an interface the
    /// OS already considered satisfied.
    ///
    /// So the probe never stops while the app is in front. Capped at 30s: past
    /// that the reconnect stops feeling automatic, and below it the cost is a
    /// two-byte round trip to a machine on the same tailnet.
    private static let sustainedDelays: [Double] = [2, 4, 8, 15, 30]

    /// Whether the app is in the foreground. The sustained ladder is a
    /// foreground behaviour ONLY - polling a server from the background is
    /// both useless (the app cannot draw the result) and rude to the battery.
    private var isActive = true

    /// True once the app has told the user it cannot reach the server, and
    /// until it can again. This, not `connection`, is what defines the
    /// transition `onlineGeneration` counts: a single failed attempt inside
    /// the launch ladder is not an outage, because nothing was ever shown.
    private var isUnreachable = false

    init(defaults: UserDefaults? = nil, tokenStore: TokenStoring? = nil) {
        // UI tests get a throwaway defaults suite and an in-memory token, so a
        // run never inherits whatever server the simulator was last pointed at
        // — otherwise the suite passes or fails based on leftover state.
        let isUITesting = RuntimeMode.isUITesting
        self.defaults = defaults
            ?? (isUITesting ? UserDefaults(suiteName: "ataru.uitests")! : .standard)
        self.tokenStore = tokenStore ?? (isUITesting ? InMemoryTokenStore() : KeychainTokenStore())
        if isUITesting { self.defaults.removePersistentDomain(forName: "ataru.uitests") }

        // The UI suite runs against the sample files, and now says so by
        // having NO address rather than by setting a mode that no longer
        // exists. Without this it would inherit the default base URL baked in
        // at build time and try to reach the real server from a simulator.
        var forTesting = AppConfiguration.default
        forTesting.baseURLString = ""
        let loaded = isUITesting
            ? forTesting
            : (Self.loadConfiguration(from: self.defaults) ?? .default)
        self.configuration = loaded
        // Demo until proven otherwise: a first launch with no server
        // configured should show a working app, not an error screen.
        self.service = DemoATARUService()
        rebuildService()
        // A path that comes up mid-backoff gets a probe immediately, rather
        // than waiting out whatever rung the ladder is on.
        reachability.onPathRestored = { [weak self] in
            self?.hasNetworkPath = true
            self?.probeConnection(reason: "the network path came back")
        }
        // Recorded, not acted on. Losing the path is not itself a reason to
        // probe - there is nothing to probe over - but it IS what decides
        // which of the two offline messages the banner shows.
        reachability.onPathLost = { [weak self] in
            self?.hasNetworkPath = false
            // Counts as an outage even though no probe has failed yet. The
            // banner is already saying "no network", so the app HAS told the
            // user it is offline - and without this, airplane mode on and off
            // again would restore the connection without ever bumping
            // `onlineGeneration`, leaving every open screen on the data it had
            // before the flight.
            self?.isUnreachable = true
        }
        reachability.start()
        morningObserver = morning.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    var freshness: DataFreshness {
        if isDemo { return .demo }
        // Order matters. "No network" outranks "cannot reach the server",
        // because with no path the Tailscale advice is advice that cannot
        // work, and sending someone to a settings screen that will not help
        // is worse than saying nothing.
        if !hasNetworkPath { return .noNetwork }
        if case .failed = connection { return .unreachable(lastConnectedAt) }
        return .live
    }

    /// True while the app has no working route to the server - either reason.
    /// The screens that hide a control during an outage ask this rather than
    /// re-deriving it.
    var isOffline: Bool { !isDemo && freshness.isOffline }

    /// The bearer token, if one is set. Read from the Keychain each time
    /// rather than cached in memory.
    var token: String? { tokenStore.token }

    func setToken(_ value: String?) {
        tokenStore.token = value
        rebuildService()
    }

    /// Saves a new address and a new token as one change.
    ///
    /// THE BUG THIS FIXES. Settings used to call `setToken` and then assign
    /// `configuration`, and each of those rebuilds the service on its own. The
    /// FIRST rebuild therefore paired the NEW token with the OLD base URL -
    /// and `rebuildService` registers the push token, so moving the app to a
    /// second server handed that server's credential to the one being left
    /// behind before anything reached the new address. It also bumped
    /// `serviceGeneration` twice, so every `.task(id:)` in the app ran its
    /// whole load twice on one tap of Save.
    ///
    /// Both fields are staged, then one rebuild, then one generation.
    func apply(configuration newConfiguration: AppConfiguration, token newToken: String?) {
        isStaging = true
        tokenStore.token = newToken
        configuration = newConfiguration
        isStaging = false
        rebuildService()
    }

    /// One probe, and its answer is the verdict.
    ///
    /// For Settings' "Save and test" only, where the user has just asked a
    /// direct question and deserves a direct answer - including "no". Cancels
    /// any running ladder first, so a backoff started at launch cannot land a
    /// late failure on top of a save that just succeeded.
    func refreshConnection() async {
        probe?.cancel()
        probe = nil
        guard !isDemo else {
            connection = .connected("demo")
            return
        }
        connection = .checking
        do {
            let detail = try await service.checkStatus()
            markReachable(detail: detail)
        } catch {
            markUnreachable(Self.message(for: error))
            // The answer stands, and the app keeps trying underneath it. A
            // "Save and test" that failed because the tunnel was not up yet
            // used to end the story: the verdict was final and nothing
            // re-probed until the next foreground.
            resumeProbing(reason: "after a failed connection test")
        }
    }

    /// Probe, and keep probing: launch, foreground, and the network path
    /// coming back.
    ///
    /// THE BUG THIS FIXES. The app showed "couldn't connect" on a launch where
    /// the network was fine. One probe ran, from `RootView.task` - about as
    /// early as anything can run, and reliably before the Tailscale path is up
    /// - and its single negative became the published state. Nothing ever
    /// re-probed, so the banner stayed until the URL was re-saved by hand.
    ///
    /// Three properties, and each one is a separate half of that:
    ///
    /// 1. A failure is only published once the whole ladder is spent. Until
    ///    then the state is `.checking`, which draws no banner at all - a
    ///    stale negative from second one is now structurally unrepresentable.
    /// 2. A success clears the failure immediately, from any rung.
    /// 3. It runs again on every foreground and every path restoration, so
    ///    "connected once, wrong forever" cannot happen either.
    func probeConnection(reason: String = "launch") {
        probe?.cancel()
        guard !isDemo else {
            connection = .connected("demo")
            return
        }
        probe = Task { [weak self] in
            await self?.runProbe(reason: reason, graceAttempts: Self.retryDelays.count + 1)
        }
    }

    /// Keeps probing when a verdict is already on screen.
    ///
    /// Same loop, no grace: the failure has already been published, so there
    /// is nothing to withhold and nothing to downgrade. This is what runs for
    /// as long as the app is unreachable and in front.
    private func resumeProbing(reason: String) {
        probe?.cancel()
        guard !isDemo else { return }
        probe = Task { [weak self] in
            await self?.runProbe(reason: reason, graceAttempts: 0)
        }
    }

    /// The app came back to the foreground.
    ///
    /// Both halves matter: re-probe now (a verdict from whenever the app was
    /// last in front is not evidence about now), and let the sustained ladder
    /// run again.
    func sceneBecameActive() {
        isActive = true
        probeConnection(reason: "foreground")
    }

    /// The app left the foreground. The ladder stops here rather than running
    /// on into the background against a server it could not draw an answer
    /// from anyway.
    func sceneResignedActive() {
        isActive = false
        probe?.cancel()
        probe = nil
    }

    /// One probe loop, with two callers and one difference between them.
    ///
    /// `graceAttempts` is how many failures may pass before the app is willing
    /// to SAY it cannot connect. At launch that is the whole first ladder - a
    /// negative from second one is the common case on a cold start, before the
    /// Tailscale path exists, and publishing it produces a banner that then
    /// sticks. Once a failure is on screen the grace is zero, because the
    /// thing it protects against has already happened.
    ///
    /// The loop itself does not end on failure. It ends on success, on
    /// cancellation, or when the app stops being in the foreground.
    private func runProbe(reason: String, graceAttempts: Int) async {
        // Never a downgrade on the way in. A working connection that is being
        // re-checked in the background is still a working connection, and
        // flashing "Testing…" over it on every foreground is noise - and a
        // failure already on screen must not flicker back to "Testing…" on
        // every rung of a ladder that may run for minutes.
        if !connection.isConnected, graceAttempts > 0 { connection = .checking }
        var lastMessage = APIError.notConfigured.localizedDescription
        var attempt = 0
        var sustained = 0

        while !Task.isCancelled {
            if attempt > 0 {
                let delay: Double
                if attempt <= Self.retryDelays.count, graceAttempts > 0 {
                    delay = Self.retryDelays[attempt - 1]
                } else {
                    delay = Self.sustainedDelays[min(sustained,
                                                     Self.sustainedDelays.count - 1)]
                    sustained += 1
                }
                try? await Task.sleep(for: .seconds(delay))
                if Task.isCancelled { return }
            }
            attempt += 1

            // Re-read every time: Settings can replace the service mid-ladder,
            // and the probe should follow the app rather than the instance it
            // started with.
            guard !isDemo else {
                connection = .connected("demo")
                return
            }
            // Backgrounded mid-ladder. Stop rather than spin; `sceneBecameActive`
            // starts a fresh one on the way back in, which is also when its
            // answer first becomes worth having.
            guard isActive else { return }

            do {
                let detail = try await service.checkStatus()
                if Task.isCancelled { return }
                netLog.notice("""
                    connected on attempt \(attempt, privacy: .public) \
                    (\(reason, privacy: .public))
                    """)
                markReachable(detail: detail)
                return
            } catch {
                if Task.isCancelled { return }
                lastMessage = Self.message(for: error)
                netLog.notice("""
                    probe attempt \(attempt, privacy: .public) failed: \
                    \(lastMessage, privacy: .public)
                    """)
                if attempt >= max(graceAttempts, 1) {
                    markUnreachable(lastMessage)
                }
            }
        }
    }

    /// The server answered.
    ///
    /// The generation bump is here and nowhere else, and it is conditional on
    /// the app having actually been unreachable - a launch that connects on
    /// the second rung never told the user anything, so it is not a
    /// reconnection and must not make every mounted screen refetch.
    private func markReachable(detail: String?) {
        let wasUnreachable = isUnreachable
        isUnreachable = false
        connection = .connected(detail)
        lastConnectedAt = Date()
        guard wasUnreachable else { return }
        onlineGeneration += 1
        netLog.notice("""
            back online, generation \(self.onlineGeneration, privacy: .public)
            """)
        // A socket opened before the outage is dead whatever it thinks. Left
        // in place, the next question spends its whole 15s receive window
        // finding that out before falling back - which on the call screen is
        // fifteen seconds of an orb thinking about nothing.
        droppedStaleStreams()
    }

    private func markUnreachable(_ message: String) {
        isUnreachable = true
        // Only when it actually changes. The sustained ladder re-publishes the
        // same failure every few seconds otherwise, and every one of those is
        // an `objectWillChange` that redraws the whole app for no new
        // information.
        guard connection != .failed(message) else { return }
        connection = .failed(message)
    }

    /// Whoever holds a WebSocket is told to let go of it.
    ///
    /// Done by notification rather than by reaching into the two models: the
    /// call session is owned by `CallStack` and the Ask model by its view, and
    /// AppState has no business knowing either. Both listen.
    private func droppedStaleStreams() {
        NotificationCenter.default.post(name: .ataruConnectionRestored, object: nil)
    }

    private static func message(for error: Error) -> String {
        (error as? APIError)?.localizedDescription ?? error.localizedDescription
    }

    /// Drops what this app has pulled onto the phone.
    ///
    /// TWO CALLERS, and they do not mean the same thing. Backgrounding drops
    /// the downloaded document files, which is what the Settings copy has
    /// always promised. Settings' own button is a person saying "delete what
    /// is on this phone", and that has to include the tile screens' cached
    /// payloads - finance, health and journal among them - or the button is
    /// not the claim it appears to be.
    ///
    /// The tile cache is deliberately NOT dropped on backgrounding: its whole
    /// job is to have something to draw on the next cold open, and clearing it
    /// every time the app leaves the foreground would delete it before it is
    /// ever read. It is written locked-device-protected instead. See TileCache.
    func purgeDownloads(includingCachedTiles: Bool = false) {
        if includingCachedTiles { TileCache.purge() }
        Task { await DocumentDownloadStore.shared.purge() }
    }

    /// THE ADDRESS DECIDES EVERYTHING.
    ///
    /// A usable URL gets the live service pointed at it. No URL, or one that
    /// does not validate, falls back to Demo - which is not a mode the user
    /// chose, it is what "there is nowhere to ask" has to look like. That
    /// fallback is also why `DemoATARUService` survived the removal of the
    /// Demo/Live switch: the app must stay usable, and the previews and tests
    /// run against it.
    private func rebuildService() {
        let store = tokenStore
        if let baseURL = configuration.baseURL {
            // Re-set on every rebuild, which is what keeps the tile screens
            // pointed at the same server and credential as the assistant when
            // Settings changes the backend.
            ATARUAuth.configure(baseURL: baseURL, tokenProvider: { store.token })
            do {
                service = try LiveATARUService(configuration: configuration,
                                               tokenProvider: { store.token })
                isDemo = false
                connection = .unknown
            } catch {
                // Validated above, so this is not reachable through Settings -
                // but a service the app cannot construct must never leave it
                // with no service at all.
                service = DemoATARUService()
                isDemo = true
                connection = .failed(APIError.notConfigured.localizedDescription)
            }
        } else {
            // Demo talks to nothing, so nothing may carry a token.
            ATARUAuth.configure(baseURL: nil, tokenProvider: { nil })
            service = DemoATARUService()
            isDemo = true
            connection = .connected("demo")
        }
        serviceGeneration += 1
        // The shared "I'm up" model follows the backend here rather than in
        // each of the three views that draw it - two of which used to point
        // their own private copy at a different service on a different
        // schedule.
        morning.update(service: service)
        // PUSH FOLLOWS THE CREDENTIAL, IMMEDIATELY.
        //
        // Saving a new token in Settings used to change nothing about push
        // until the next cold launch: the token this phone was registered with
        // had been uploaded under the old credential, and the upload was only
        // repeated when `RootView` noticed the service had changed - which it
        // did by object identity, and so sometimes did not notice at all (see
        // `serviceGeneration`). He hit this live: saved the token, and the
        // morning call could not ring the phone.
        //
        // Doing it here rather than in Settings covers every way the backend
        // can change - the token, the URL, a Demo ⇄ Live flip - with one call,
        // and it cannot be forgotten by a future caller. `update` is a no-op
        // until a token exists, so the one at init costs nothing.
        RemotePushService.shared.update(service: service)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(configuration) else { return }
        defaults.set(data, forKey: Self.configurationKey)
    }

    private static func loadConfiguration(from defaults: UserDefaults) -> AppConfiguration? {
        guard let data = defaults.data(forKey: configurationKey) else { return nil }
        return try? JSONDecoder().decode(AppConfiguration.self, from: data)
    }
}

extension Notification.Name {
    /// Posted the moment a probe succeeds after the app has told the user it
    /// could not connect. Anything holding a long-lived socket drops it here.
    static let ataruConnectionRestored = Notification.Name("com.ataru.client.connectionRestored")
}

/// Indirection over the Keychain so tests don't touch the real one.
protocol TokenStoring: Sendable {
    var token: String? { get nonmutating set }
}

/// Tokens live in the Keychain, never in UserDefaults — UserDefaults is a
/// plist in the app container and is readable from a device backup.
struct KeychainTokenStore: TokenStoring {
    private let store = KeychainStore()

    var token: String? {
        get { store.get(KeychainStore.bearerTokenAccount) }
        nonmutating set {
            guard let newValue, !newValue.isEmpty else {
                store.remove(KeychainStore.bearerTokenAccount)
                return
            }
            // A token that fails to save must not appear to have saved; the
            // Settings screen re-reads this value to confirm.
            try? store.set(newValue, for: KeychainStore.bearerTokenAccount)
        }
    }
}

/// In-memory token store for tests and previews.
final class InMemoryTokenStore: TokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?

    init(token: String? = nil) { self.value = token }

    var token: String? {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}
