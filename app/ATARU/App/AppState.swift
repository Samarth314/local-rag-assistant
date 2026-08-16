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
    @Published var configuration: AppConfiguration {
        didSet {
            guard configuration != oldValue else { return }
            persist()
            rebuildService()
        }
    }

    private let defaults: UserDefaults
    private let tokenStore: TokenStoring
    private static let configurationKey = "ataru.configuration"

    /// The launch/foreground probe, so a second one cancels the first rather
    /// than racing it to publish a verdict.
    private var probe: Task<Void, Never>?
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
            self?.probeConnection(reason: "the network path came back")
        }
        reachability.start()
    }

    var freshness: DataFreshness {
        if isDemo { return .demo }
        if case .failed = connection { return .offline(nil) }
        return .live
    }

    /// The bearer token, if one is set. Read from the Keychain each time
    /// rather than cached in memory.
    var token: String? { tokenStore.token }

    func setToken(_ value: String?) {
        tokenStore.token = value
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
            connection = .connected(detail)
        } catch {
            connection = .failed(Self.message(for: error))
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
        probe = Task { [weak self] in await self?.runProbe(reason: reason) }
    }

    private func runProbe(reason: String) async {
        // Never a downgrade on the way in. A working connection that is being
        // re-checked in the background is still a working connection, and
        // flashing "Testing…" over it on every foreground is noise.
        if !connection.isConnected { connection = .checking }
        var lastMessage = APIError.notConfigured.localizedDescription

        for attempt in 0...Self.retryDelays.count {
            if attempt > 0 {
                let delay = Self.retryDelays[attempt - 1]
                try? await Task.sleep(for: .seconds(delay))
                if Task.isCancelled { return }
            }
            // Re-read every time: Settings can replace the service mid-ladder,
            // and the probe should follow the app rather than the instance it
            // started with.
            guard !isDemo else {
                connection = .connected("demo")
                return
            }
            do {
                let detail = try await service.checkStatus()
                if Task.isCancelled { return }
                netLog.notice("""
                    connected on attempt \(attempt + 1, privacy: .public) \
                    (\(reason, privacy: .public))
                    """)
                connection = .connected(detail)
                return
            } catch {
                if Task.isCancelled { return }
                lastMessage = Self.message(for: error)
                netLog.notice("""
                    probe attempt \(attempt + 1, privacy: .public) failed: \
                    \(lastMessage, privacy: .public)
                    """)
            }
        }
        guard !Task.isCancelled else { return }
        connection = .failed(lastMessage)
    }

    private static func message(for error: Error) -> String {
        (error as? APIError)?.localizedDescription ?? error.localizedDescription
    }

    /// Drops every document this app has pulled onto the phone.
    func purgeDownloads() {
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
