import Foundation
import Network
import OSLog

/// Whether this device has a network path at all, and a callback for the
/// moment it gets one.
///
/// ## The bug this exists for
///
/// ATARU said "couldn't connect" seconds after a cold launch while the network
/// was completely fine. The probe ran ONCE, from `RootView.task`, which is
/// about as early as an app can run anything — and on a phone that is exactly
/// when the Tailscale path is still coming up. The single negative it got was
/// then published as the connection state and stayed there: nothing re-probed
/// on its own, so the banner survived until the URL was re-saved in Settings
/// by hand.
///
/// A retry ladder alone would fix the common case. This is the other half: a
/// phone that walks out of Wi-Fi range, or wakes with the tunnel down, gets a
/// probe at the exact moment the path comes back rather than at the end of
/// whatever backoff happened to be running.
///
/// ## What it does not claim
///
/// A satisfied path means the OS has an interface it believes can carry
/// traffic. It says nothing about the tailnet being up, the mini being awake,
/// or the server answering — all of which is what the probe itself is for.
/// This only ever *starts* work; it never reports success on the probe's
/// behalf.
@MainActor
final class Reachability: ObservableObject {

    /// False only when the OS says there is no usable path at all. Starts true
    /// on purpose: "we have not heard yet" must never read as "offline".
    @Published private(set) var isSatisfied = true

    /// Called every time the path becomes satisfied after not being — a
    /// transition, not a level, so a stable connection does not re-probe on
    /// every unrelated path update (a Wi-Fi roam, a VPN interface appearing).
    var onPathRestored: (() -> Void)?

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.ataru.client.reachability")
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor in self?.apply(satisfied) }
        }
        monitor.start(queue: queue)
    }

    private func apply(_ satisfied: Bool) {
        let wasSatisfied = isSatisfied
        guard satisfied != wasSatisfied else { return }
        isSatisfied = satisfied
        netLog.notice("network path \(satisfied ? "satisfied" : "unsatisfied", privacy: .public)")
        if satisfied { onPathRestored?() }
    }

    deinit { monitor.cancel() }
}

let netLog = Logger(subsystem: "com.ataru.client", category: "network")
