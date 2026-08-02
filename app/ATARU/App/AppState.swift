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

    init(defaults: UserDefaults? = nil, tokenStore: TokenStoring? = nil) {
        // UI tests get a throwaway defaults suite and an in-memory token, so a
        // run never inherits whatever server the simulator was last pointed at
        // — otherwise the suite passes or fails based on leftover state.
        let isUITesting = RuntimeMode.isUITesting
        self.defaults = defaults
            ?? (isUITesting ? UserDefaults(suiteName: "ataru.uitests")! : .standard)
        self.tokenStore = tokenStore ?? (isUITesting ? InMemoryTokenStore() : KeychainTokenStore())
        if isUITesting { self.defaults.removePersistentDomain(forName: "ataru.uitests") }

        let loaded = isUITesting ? .default : (Self.loadConfiguration(from: self.defaults) ?? .default)
        self.configuration = loaded
        // Demo until proven otherwise: a first launch with no server
        // configured should show a working app, not an error screen.
        self.service = DemoATARUService()
        rebuildService()
    }

    var freshness: DataFreshness {
        switch (configuration.mode, connection) {
        case (.demo, _): return .demo
        case (.live, .connected): return .live
        case (.live, .failed): return .offline(nil)
        case (.live, _): return .live
        }
    }

    /// The bearer token, if one is set. Read from the Keychain each time
    /// rather than cached in memory.
    var token: String? { tokenStore.token }

    func setToken(_ value: String?) {
        tokenStore.token = value
        rebuildService()
    }

    /// Probes the backend and records the result for the Settings screen.
    func refreshConnection() async {
        guard configuration.mode == .live else {
            connection = .connected("demo")
            return
        }
        connection = .checking
        do {
            let detail = try await service.checkStatus()
            connection = .connected(detail)
        } catch {
            connection = .failed((error as? APIError)?.localizedDescription
                                 ?? error.localizedDescription)
        }
    }

    /// Drops every document this app has pulled onto the phone.
    func purgeDownloads() {
        Task { await DocumentDownloadStore.shared.purge() }
    }

    private func rebuildService() {
        switch configuration.mode {
        case .demo:
            service = DemoATARUService()
            connection = .connected("demo")
        case .live:
            let store = tokenStore
            do {
                service = try LiveATARUService(configuration: configuration,
                                               tokenProvider: { store.token })
                connection = .unknown
            } catch {
                // A malformed base URL must not leave the app with no service
                // at all; Demo keeps it usable while Settings is corrected.
                service = DemoATARUService()
                connection = .failed(APIError.notConfigured.localizedDescription)
            }
        }
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
