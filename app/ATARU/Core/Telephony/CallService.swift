import CallKit
import AVFoundation
import Combine
import Foundation
import UIKit

/// Where a call sits in its lifecycle.
///
/// Deliberately one enum rather than a set of booleans: the call screen, the
/// system call UI and the audio session all read from this, and a disagreement
/// between them shows up as a call the user can see but cannot hang up.
enum CallState: Equatable {
    case idle
    /// We asked the system to place a call; it has not connected yet.
    case dialing
    /// The system is showing the full-screen incoming-call UI.
    case incoming
    case active(connectedAt: Date)
    case ended(CallEndReason)

    var isLive: Bool {
        switch self {
        case .dialing, .incoming, .active: return true
        case .idle, .ended: return false
        }
    }

    /// Uppercase label for the call screen — the kit's `callState` style.
    var label: String {
        switch self {
        case .idle: return "Ready"
        case .dialing: return "Calling"
        case .incoming: return "Incoming"
        case .active: return "Connected"
        case .ended(let reason): return reason.label
        }
    }
}

enum CallEndReason: Equatable {
    case hungUp
    case declined
    case failed(String)
    /// The system tore everything down — `providerDidReset`.
    case reset

    var label: String {
        switch self {
        case .hungUp: return "Call ended"
        case .declined: return "Declined"
        case .failed: return "Call failed"
        case .reset: return "Call ended"
        }
    }
}

/// Bridges ATARU to the system call UI via CallKit.
///
/// The point of CallKit here is that talking to ATARU should feel like a phone
/// call rather than like using an app: full-screen incoming UI, an entry in
/// Recents, hardware mute, and the ability to answer from the lock screen. It
/// is the same conversation the telephony front door already offers over SIP —
/// this is that conversation without the PSTN in the middle.
///
/// ## What this class does and does not own
///
/// It owns the CallKit objects and the call's state. It does **not** own the
/// conversation: `onAudioActivated` hands control to `CallSessionModel` once the
/// system has actually given us the audio route. That split matters because the
/// audio session is activated by the system, not by us — starting to speak
/// before `provider(_:didActivate:)` produces silence.
///
/// ## Demo mode
///
/// `reportIncomingCall(after:)` fakes a call *from* ATARU. In a shipping app the
/// trigger would be a PushKit VoIP push from the Orin, and iOS requires that
/// every VoIP push be answered with `reportNewIncomingCall` or it will kill the
/// app and eventually revoke push privileges. Locally reported calls have no
/// such contract, which is what makes them usable for a demo.
@MainActor
final class CallService: NSObject, ObservableObject {

    @Published private(set) var state: CallState = .idle
    @Published private(set) var isMuted = false
    /// Speakerphone, on by default.
    ///
    /// A call to ATARU is not a private conversation with a person — it is
    /// asking a machine a question, usually with the phone on a desk rather
    /// than against an ear. Defaulting to the receiver would mean lifting the
    /// phone to hear every answer.
    @Published private(set) var isSpeakerOn = true

    /// Called once the system has activated the audio session, which is the
    /// only safe moment to start playing or recording.
    var onAudioActivated: (() -> Void)?
    /// Called when the route goes away — stop everything immediately.
    var onAudioDeactivated: (() -> Void)?
    /// Actually stops or resumes the microphone. CallKit's mute action is
    /// bookkeeping and does not touch audio, so without this the call would
    /// display "muted" while still listening to the room.
    var onMuteChanged: ((Bool) -> Void)?

    private let provider: CXProvider
    private let controller = CXCallController()
    /// The one call we allow at a time. CallKit is happy to track several; a
    /// single assistant that can only hold one conversation is not.
    private var callID: UUID?
    /// Whether `provider(_:didActivate:)` has arrived for the current call.
    private var didActivateAudio = false

    /// Nonisolated so it can be used as a default argument to `init`, which the
    /// caller may reach from outside the main actor.
    nonisolated static var providerConfiguration: CXProviderConfiguration {
        let configuration = CXProviderConfiguration()
        // No localizedName here: it is get-only on the modern initializer and
        // the system takes the name it shows on the lock screen from the
        // bundle's display name. `init(localizedName:)` still exists but is
        // deprecated, and setting it would only restate CFBundleName.
        configuration.supportsVideo = false
        configuration.maximumCallGroups = 1
        configuration.maximumCallsPerCallGroup = 1
        // `.generic` rather than `.phoneNumber`: ATARU has no number, and
        // claiming one would put a tappable non-number in the system UI.
        configuration.supportedHandleTypes = [.generic]
        // On, so ATARU appears in the Phone app's Recents and tapping an entry
        // redials it. That tap is the whole point: it is the shortest path from
        // "I want to ask something" to talking, and it needs no contact card,
        // no Siri, and no launching the app.
        //
        // The cost, stated plainly: Recents is not a local-only list. With Call
        // History sync on, entries reach iCloud and the user's other devices —
        // so *when* the vault was consulted leaves the phone, even though
        // nothing that was asked or answered ever does. Turning off Settings →
        // Apple ID → iCloud → Call History keeps the redial and drops the sync.
        configuration.includesCallsInRecents = true
        return configuration
    }

    init(provider: CXProvider = CXProvider(configuration: CallService.providerConfiguration)) {
        self.provider = provider
        super.init()
        // A nil queue means the main queue, which is what the `assumeIsolated`
        // calls in the delegate methods below rely on.
        provider.setDelegate(self, queue: nil)
    }

    // MARK: - Placing and ending

    /// Places an outgoing call to ATARU.
    func call() {
        guard !state.isLive else { return }
        let id = UUID()
        callID = id
        state = .dialing

        let action = CXStartCallAction(call: id, handle: Self.handle)
        action.isVideo = false
        request(action, fatal: true)
    }

    /// Fakes an incoming call from ATARU, optionally after a delay so the
    /// device can be locked first — the system's full-screen UI only appears
    /// when the app is not already frontmost, which is most of the point of
    /// CallKit.
    ///
    /// **This path cannot be verified in the Simulator.** A reported incoming
    /// call is declined by the system within about a second there, so the call
    /// goes `.incoming` → `.ended(.declined)` before anything can be seen or
    /// answered. Outgoing calls are unaffected and do work in the Simulator.
    /// Test incoming calls on a device.
    func reportIncomingCall(after delay: TimeInterval = 0) {
        guard !state.isLive else { return }
        Task { [weak self] in
            // Locking the phone suspends the app, which would freeze the sleep
            // below and mean the call never rings — the exact scenario this
            // button exists to demonstrate. A background task assertion keeps
            // the process alive long enough to report it.
            //
            // This covers a countdown started by hand, and nothing more. A real
            // "ATARU rings you" while the app is closed for hours needs a
            // PushKit VoIP push from the server; there is no client-side timer
            // that survives that, by design.
            var assertion = UIBackgroundTaskIdentifier.invalid
            if delay > 0 {
                assertion = UIApplication.shared.beginBackgroundTask(withName: "ataru.test-call") {
                    // Expiry handler. iOS grants roughly 30 seconds; a 5-second
                    // countdown is well inside that, so this is a formality the
                    // system requires rather than a path that should run.
                }
                try? await Task.sleep(for: .seconds(delay))
            }
            defer {
                if assertion != .invalid {
                    UIApplication.shared.endBackgroundTask(assertion)
                }
            }

            guard let self, !self.state.isLive else { return }

            let id = UUID()
            self.callID = id

            let update = CXCallUpdate()
            update.remoteHandle = Self.handle
            update.localizedCallerName = "ATARU"
            update.hasVideo = false
            update.supportsGrouping = false
            update.supportsUngrouping = false
            update.supportsHolding = false
            update.supportsDTMF = false

            self.state = .incoming
            do {
                try await self.provider.reportNewIncomingCall(with: id, update: update)
            } catch {
                // Most commonly this is CallKit being unavailable — it is
                // disabled entirely in mainland China — so say what happened
                // rather than leaving a call screen that never rings.
                self.callID = nil
                self.state = .ended(.failed(error.localizedDescription))
            }
        }
    }

    /// Reports a call that arrived as a VoIP push.
    ///
    /// Separate from `reportIncomingCall(after:)` because the contract is
    /// different: there is no delay, no `isLive` guard that could skip the
    /// report, and the completion must not run until CallKit has the call.
    /// PushKit requires a report for *every* push — see `VoIPPushService` — so
    /// this method has no path that returns without reporting one.
    func reportPushedCall(reason: String?, completion: @escaping () -> Void) {
        // An existing call is not a reason to skip: iOS still demands a report.
        // Ending the old one first keeps the single-call invariant.
        if state.isLive, let existing = callID {
            provider.reportCall(with: existing, endedAt: Date(), reason: .remoteEnded)
            callID = nil
        }

        let id = UUID()
        callID = id
        state = .incoming

        let update = CXCallUpdate()
        update.remoteHandle = Self.handle
        update.localizedCallerName = "ATARU"
        update.hasVideo = false
        update.supportsGrouping = false
        update.supportsUngrouping = false
        update.supportsHolding = false
        update.supportsDTMF = false

        provider.reportNewIncomingCall(with: id, update: update) { [weak self] error in
            Task { @MainActor in
                if let error {
                    self?.callID = nil
                    self?.state = .ended(.failed(error.localizedDescription))
                }
                completion()
            }
        }
    }

    /// Answers a ringing call from ATARU's own UI.
    ///
    /// Needed because the system only draws its full-screen incoming UI when
    /// this app is *not* frontmost; with the app open, iOS shows a compact
    /// banner and expects the app to present its own call screen. That screen
    /// needs a way to accept, and this is it.
    ///
    /// Requested through `CXCallController` rather than by flipping state
    /// directly, so an in-app answer and a lock-screen answer both arrive at
    /// `provider(_:perform: CXAnswerCallAction)` and cannot diverge.
    func answer() {
        guard case .incoming = state, let id = callID else { return }
        request(CXAnswerCallAction(call: id), fatal: true)
    }

    /// Hangs up. Routed through `CXCallController` rather than reported
    /// directly, so the system UI and this object end the call by the same
    /// path whether the user tapped our button or the one in the status bar.
    func end() {
        guard let id = callID else {
            state = .idle
            return
        }
        request(CXEndCallAction(call: id), fatal: true)
    }

    /// Mutes or unmutes the microphone.
    ///
    /// Applied locally first, then asked of CallKit. Waiting for the round trip
    /// meant the button did nothing visible until the delegate came back — and
    /// when it never came back, the button looked broken while the microphone
    /// stayed live. Muting has to be believable the instant it is pressed.
    ///
    /// `onMuteChanged` is what actually stops the microphone. CallKit's action
    /// is bookkeeping — it tells the system so the lock screen and Watch agree
    /// — but it does not touch audio. Without that callback, "muted" was a
    /// label on a microphone that was still listening.
    func setMuted(_ muted: Bool) {
        guard let id = callID, isMuted != muted else { return }
        let previous = isMuted

        applyMute(muted)

        request(CXSetMutedCallAction(call: id, muted: muted), fatal: false) { [weak self] in
            self?.applyMute(previous)
        }
    }

    /// The single place mute state changes, whichever surface asked.
    ///
    /// Idempotent, because a change can arrive twice: the app button applies it
    /// optimistically and the CallKit delegate then confirms the same value.
    private func applyMute(_ muted: Bool) {
        guard isMuted != muted else { return }
        isMuted = muted
        onMuteChanged?(muted)
    }

    /// Routes audio to the speaker or back to the receiver.
    ///
    /// Not a CallKit action — CallKit has no concept of speakerphone, so unlike
    /// mute this is set directly on the audio session. The system call UI's own
    /// speaker button drives the same override, so the two stay consistent by
    /// acting on the same thing rather than by being kept in step.
    func setSpeaker(_ on: Bool) {
        isSpeakerOn = on
        applyAudioRoute()
    }

    private func applyAudioRoute() {
        do {
            try AVAudioSession.sharedInstance()
                .overrideOutputAudioPort(isSpeakerOn ? .speaker : .none)
        } catch {
            // The route request failed, so the state we are showing would be a
            // lie. Read it back from the session instead of asserting it.
            isSpeakerOn = AVAudioSession.sharedInstance().currentRoute.outputs
                .contains { $0.portType == .builtInSpeaker }
        }
    }

    /// Submits a CallKit action.
    ///
    /// - Parameter fatal: whether failing this action means the call is over.
    ///   Starting, answering and ending are fatal — if one fails there is no
    ///   working call left. Mute is **not**: a mute that does not go through is
    ///   an unmuted call, not a dead one, and treating every failure the same
    ///   way meant a couple of taps on mute would hang up.
    /// Submits a CallKit action.
    ///
    /// - Parameters:
    ///   - fatal: whether failing this action means the call is over. Starting,
    ///     answering and ending are fatal — if one fails there is no working
    ///     call left. Mute is **not**: a mute that does not go through leaves an
    ///     unmuted call, not a dead one. Treating every failure identically is
    ///     what made a couple of taps on mute hang up.
    ///   - onFailure: undoes whatever was applied optimistically.
    private func request(_ action: CXAction, fatal: Bool,
                         onFailure: (@MainActor () -> Void)? = nil) {
        controller.request(CXTransaction(action: action)) { [weak self] error in
            guard error != nil else { return }
            Task { @MainActor in
                guard let self else { return }
                onFailure?()
                guard fatal else { return }
                // A failed transaction means CallKit never learned the call is
                // over, so clearing local state alone dismisses the app's call
                // UI and leaves the system's running — one the user has
                // "ended" that still holds the audio route.
                self.teardown(reason: .failed(error?.localizedDescription ?? "Call failed."),
                              notifyProvider: true)
            }
        }
    }

    nonisolated private static var handle: CXHandle {
        CXHandle(type: .generic, value: "ATARU")
    }

    // MARK: - Audio

    /// Prepares the session for a voice call.
    ///
    /// Note what is missing: `setActive(true)`. Under CallKit the system
    /// activates the session and then calls `provider(_:didActivate:)`.
    /// Activating it here fights the system and loses the route.
    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            // No `.defaultToSpeaker` here, deliberately: with it set, the
            // session's *default* route is the speaker, so clearing the
            // override (`.none`) lands right back on the speaker and the
            // toggle's off position does nothing. Speakerphone-by-default is
            // done instead by applying the `.speaker` override once the
            // session activates, which leaves `.none` genuinely meaning
            // the receiver.
            try session.setCategory(.playAndRecord, mode: .voiceChat,
                                    options: [.allowBluetooth, .allowBluetoothA2DP])
            try session.setPreferredIOBufferDuration(0.005)
        } catch {
            // A call with a degraded session still beats no call; the failure
            // surfaces as poor audio rather than as a dead screen.
        }
    }

    /// Clears local call state.
    ///
    /// - Parameter notifyProvider: whether CallKit still believes the call is
    ///   up. Pass `true` from any path that gives up locally — a failed or
    ///   timed-out transaction — because otherwise the system keeps a call the
    ///   app has already forgotten and the two can never be reconciled. Pass
    ///   `false` from the delegate, where CallKit is the one telling *us*.
    private func teardown(reason: CallEndReason, notifyProvider: Bool = false) {
        if notifyProvider, let id = callID {
            provider.reportCall(with: id, endedAt: Date(), reason: .failed)
        }

        // Donate before clearing state — this is what teaches iOS to offer
        // ATARU on a contact card. Only completed calls count: donating a
        // dialing-then-failed call would advertise a way to reach something
        // that did not answer.
        if case .active(let connectedAt) = state {
            CallIntent.donate(startedAt: connectedAt, endedAt: Date())
        }
        callID = nil
        isMuted = false
        didActivateAudio = false
        state = .ended(reason)
        onAudioDeactivated?()
    }

    /// Starts the conversation even if the system never hands us the audio
    /// session.
    ///
    /// The Simulator does not activate audio sessions for CallKit calls, so
    /// `provider(_:didActivate:)` never arrives there and the call would sit
    /// connected and silent — which is exactly the state you cannot debug,
    /// because it looks identical to a broken conversation loop. On a device
    /// the callback lands in milliseconds and this no-ops.
    ///
    /// Note the ordering rule this bends: normally you must not touch audio
    /// before the system activates the session. Waiting first, and only acting
    /// if the callback never came, keeps device behaviour unchanged.
    private func startConversationIfSystemStaysQuiet() {
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard let self, !self.didActivateAudio, case .active = self.state else { return }
            self.onAudioActivated?()
        }
    }
}

// MARK: - CXProviderDelegate
//
// The delegate queue is the main queue (`setDelegate(_:queue: nil)`), so these
// hop straight onto the main actor rather than dispatching again.

extension CallService: CXProviderDelegate {

    nonisolated func providerDidReset(_ provider: CXProvider) {
        MainActor.assumeIsolated {
            // Everything the system knew about is gone. Drop state without
            // requesting an end action — there is nothing left to end.
            callID = nil
            isMuted = false
            state = .ended(.reset)
            onAudioDeactivated?()
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        MainActor.assumeIsolated {
            configureAudioSession()
            action.fulfill()

            provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: nil)
            // Nothing to negotiate with a local assistant, so it connects
            // immediately. A real transport would report this on answer.
            provider.reportOutgoingCall(with: action.callUUID, connectedAt: nil)
            state = .active(connectedAt: Date())
            startConversationIfSystemStaysQuiet()
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        MainActor.assumeIsolated {
            configureAudioSession()
            action.fulfill()
            state = .active(connectedAt: Date())
            startConversationIfSystemStaysQuiet()
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        MainActor.assumeIsolated {
            let wasAnswered = state == .active(connectedAt: Date()) || {
                if case .active = state { return true }
                return false
            }()
            action.fulfill()
            teardown(reason: wasAnswered ? .hungUp : .declined)
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        MainActor.assumeIsolated {
            // This delegate fires for BOTH origins: our own button (after the
            // transaction round-trips) and the system call UI's mute switch.
            // It must drive `onMuteChanged`, not just the flag — the system UI
            // path has no other way to reach the microphone, and skipping it
            // here is what let a lock-screen mute leave the mic recording and
            // the session permanently out of step with the call.
            applyMute(action.isMuted)
            action.fulfill()
        }
    }

    nonisolated func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        MainActor.assumeIsolated {
            didActivateAudio = true
            // The route can only be overridden once the session is active, so
            // the speaker preference is applied here rather than when it was
            // chosen. Setting it any earlier silently does nothing.
            //
            // Unless something external is already connected: forcing the
            // built-in speaker override would yank the call out of the user's
            // AirPods or car. Follow the accessory and let the toggle reflect
            // reality; tapping it still forces the speaker if that is wanted.
            let external: Set<AVAudioSession.Port> = [
                .headphones, .bluetoothA2DP, .bluetoothHFP, .bluetoothLE,
                .carAudio, .airPlay,
            ]
            if audioSession.currentRoute.outputs
                .contains(where: { external.contains($0.portType) }) {
                isSpeakerOn = false
            } else {
                applyAudioRoute()
            }
            onAudioActivated?()
        }
    }

    nonisolated func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        MainActor.assumeIsolated { onAudioDeactivated?() }
    }

    /// Called when an action was not fulfilled in time. Ending the call is the
    /// honest response — a call stuck mid-transition cannot be recovered, and
    /// leaving it up means a call the user cannot hang up.
    nonisolated func provider(_ provider: CXProvider, timedOutPerforming action: CXAction) {
        MainActor.assumeIsolated {
            teardown(reason: .failed("The call timed out while connecting."))
        }
    }
}
