import CallKit
import Combine
import Foundation
import PushKit
import UIKit

/// Receives VoIP pushes so ATARU can ring without being open.
///
/// This is what makes the assistant something you can *call* rather than an app
/// you launch. The server sends a VoIP push; iOS wakes this process in the
/// background with no UI; the app reports an incoming call; the user answers
/// from the lock screen and never sees ATARU at all.
///
/// ## The rule that governs every line here
///
/// From iOS 13, an app that receives a VoIP push and does **not** report an
/// incoming call to CallKit before the completion handler runs is terminated,
/// and an app that does it repeatedly loses the VoIP entitlement outright.
///
/// So the report is unconditional. There is no filtering on payload contents,
/// no "is the user signed in" check, no early return — every push reports a
/// call, and anything that might fail happens afterwards. This is the one place
/// in the codebase where correctness means *always doing the thing*, even when
/// the input looks wrong.
@MainActor
final class VoIPPushService: NSObject, ObservableObject {

    /// The most recent token iOS issued, hex-encoded as the server expects.
    @Published private(set) var token: String?
    /// Last registration error, surfaced in Settings so a phone that cannot be
    /// rung says so instead of just never ringing.
    @Published private(set) var registrationError: String?

    /// Which APNs host the server must push to for this build.
    ///
    /// An Xcode-installed build gets a sandbox token; TestFlight and the App
    /// Store get production ones. They are not interchangeable — sending to the
    /// wrong host fails with `BadDeviceToken` and the phone simply never rings,
    /// which is indistinguishable from a dozen other faults. The client knows
    /// which kind of build it is, so it tells the server rather than leaving it
    /// to guess.
    static var environment: String {
        #if DEBUG
        return "sandbox"
        #else
        return "production"
        #endif
    }

    private let registry = PKPushRegistry(queue: .main)
    private weak var call: CallService?
    private var service: ATARUService?
    /// The upload in flight, so a newer one supersedes it rather than racing.
    private var registration: Task<Void, Never>?
    private var foregroundObserver: NSObjectProtocol?

    /// How long to wait before the one retry. Short enough to be over before
    /// he is awake, long enough for a tailnet that is coming up to arrive.
    private static let retryDelay: Duration = .seconds(8)

    init(call: CallService) {
        self.call = call
        super.init()
        registry.delegate = self
        // Triggers `didUpdate pushCredentials` on the main queue. Do this as
        // early as the app can manage: a push that arrives before the registry
        // has a delegate is a push nobody answers.
        registry.desiredPushTypes = [.voIP]
        // A phone that failed to register is a phone that cannot be rung, and
        // nothing retried it until the next cold launch - so a token uploaded
        // while the tailnet happened to be down stayed unregistered for as
        // long as the app stayed running. Coming to the foreground is the
        // cheapest honest proxy for "the network may be back".
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.retryIfUnregistered() }
        }
    }

    deinit {
        if let foregroundObserver {
            NotificationCenter.default.removeObserver(foregroundObserver)
        }
    }

    /// Point at the current backend. Called again whenever Demo ⇄ Live flips,
    /// since a token registered with Demo reaches nothing.
    func update(service: ATARUService) {
        self.service = service
        if let token { send(token) }
    }

    /// Re-uploads only when the last attempt is known to have failed. A
    /// successful registration is idempotent server-side but not free, and
    /// re-sending on every foreground would be a request per app switch.
    private func retryIfUnregistered() {
        guard registrationError != nil, let token else { return }
        send(token)
    }

    /// Uploads the token, with one bounded retry.
    ///
    /// The failure this covers is the 7am one: the phone boots or wakes, the
    /// tailnet is not up yet, the single attempt fails, and nothing ever tries
    /// again - so the morning call rings a phone the server has no route to.
    /// One retry is deliberate rather than a loop: repeating forever against a
    /// backend that is genuinely gone would just be a background radio, and
    /// `registrationError` is surfaced in Settings for the case that persists.
    private func send(_ token: String) {
        guard let service else { return }
        registration?.cancel()
        registration = Task { @MainActor in
            for attempt in 0..<2 {
                if attempt > 0 {
                    try? await Task.sleep(for: Self.retryDelay)
                    guard !Task.isCancelled else { return }
                }
                do {
                    try await service.registerVoIPToken(token, environment: Self.environment)
                    registrationError = nil
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    registrationError = (error as? LocalizedError)?.errorDescription
                        ?? error.localizedDescription
                }
            }
        }
    }
}

// MARK: - PKPushRegistryDelegate

extension VoIPPushService: PKPushRegistryDelegate {

    nonisolated func pushRegistry(_ registry: PKPushRegistry,
                                  didUpdate pushCredentials: PKPushCredentials,
                                  for type: PKPushType) {
        let hex = pushCredentials.token.map { String(format: "%02x", $0) }.joined()
        MainActor.assumeIsolated {
            token = hex
            send(hex)
        }
    }

    nonisolated func pushRegistry(_ registry: PKPushRegistry,
                                  didInvalidatePushTokenFor type: PKPushType) {
        MainActor.assumeIsolated {
            token = nil
            registrationError = "This phone can no longer be rung. Reopen ATARU to re-register."
        }
    }

    /// Reports the incoming call. See the type's doc comment: this must happen
    /// on every push, before `completion()`, with no conditions attached.
    nonisolated func pushRegistry(_ registry: PKPushRegistry,
                                  didReceiveIncomingPushWith payload: PKPushPayload,
                                  for type: PKPushType,
                                  completion: @escaping () -> Void) {
        MainActor.assumeIsolated {
            let reason = payload.dictionaryPayload["reason"] as? String
            // `call` is weak, and the optional chain silently swallowed the
            // WHOLE statement when it was nil - completion included. A push
            // whose completion never runs is the one thing iOS terminates the
            // app for, and repeating it costs the VoIP entitlement outright.
            // There is no call to report without a CallService, but there is
            // still a completion that must run.
            guard let call else {
                completion()
                return
            }
            call.reportPushedCall(reason: reason) {
                // Only after CallKit has the call. Calling this earlier lets
                // iOS suspend the process mid-report, which reads to the system
                // as a push that never produced a call.
                completion()
            }
        }
    }
}
