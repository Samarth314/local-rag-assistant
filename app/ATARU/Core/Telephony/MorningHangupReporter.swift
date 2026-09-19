import Combine
import Foundation
import UIKit

/// Tells the server how the morning call stopped.
///
/// ## Fire and forget, and why that is the right shape
///
/// This runs from inside a CallKit delegate callback. CallKit gives an app a
/// few seconds to fulfil an action and kills the call if it does not, so
/// nothing on that path may await a network round trip - least of all at seven
/// in the morning against a tailnet that may not be up. The action is
/// fulfilled first, the report goes out afterwards, and a report that never
/// lands costs nothing: the ladder's fallback is the behaviour it already had
/// before any of this existed.
///
/// ## One retry, and a background assertion
///
/// The failure this is actually built for is the app being in the background
/// when it happens. A decline from the lock screen means the process was woken
/// by a VoIP push, reported a call, and is about to be suspended again - and a
/// suspended process does not finish a POST. `beginBackgroundTask` buys the
/// seconds that takes.
///
/// One retry rather than a loop, for the same reason `VoIPPushService` takes
/// one: repeating forever against a backend that is genuinely gone is a
/// background radio, and this is a report about a moment that has already
/// passed.
@MainActor
final class MorningHangupReporter: ObservableObject {

    /// The last thing this told the server, for Settings and for tests. Set
    /// when the attempt STARTS, not when it lands: what it records is what the
    /// phone decided, which is the part worth being able to see.
    @Published private(set) var lastReported: CallHangupReason?
    /// Why the last report did not land, or nil if it did. Nothing in the app
    /// depends on this having worked.
    @Published private(set) var lastError: String?

    /// Short. The window this has to live in is the few seconds of background
    /// time a declined call leaves behind, not a patient reconnection.
    private static let retryDelay: Duration = .seconds(3)

    private var service: ATARUService?
    /// The report in flight, so a second call ending supersedes the first
    /// rather than racing it.
    private var inFlight: Task<Void, Never>?

    /// Points at the current backend. Called from `CallStack.configure`, for
    /// the same reason the push service is: a report sent to the backend the
    /// app was pointed at an hour ago reaches nothing.
    func update(service: ATARUService) {
        self.service = service
    }

    /// Sends one report. Returns immediately.
    func report(_ reason: CallHangupReason, at moment: Date = Date()) {
        guard let service else { return }
        lastReported = reason
        inFlight?.cancel()

        // Taken BEFORE the task starts. Beginning it inside would already be
        // too late on the path this exists for - the process can be suspended
        // between the delegate returning and the task being scheduled.
        let assertion = UIApplication.shared.beginBackgroundTask(
            withName: "ataru.call-hangup")

        inFlight = Task { @MainActor in
            defer {
                if assertion != .invalid {
                    UIApplication.shared.endBackgroundTask(assertion)
                }
            }
            for attempt in 0..<2 {
                if attempt > 0 {
                    try? await Task.sleep(for: Self.retryDelay)
                    guard !Task.isCancelled else { return }
                }
                do {
                    try await service.reportCallHangup(reason: reason, at: moment)
                    lastError = nil
                    callLog.notice("hangup reported: \(reason.rawValue, privacy: .public)")
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    lastError = (error as? LocalizedError)?.errorDescription
                        ?? error.localizedDescription
                }
            }
            callLog.notice("hangup report failed: \(self.lastError ?? "", privacy: .public)")
        }
    }
}
