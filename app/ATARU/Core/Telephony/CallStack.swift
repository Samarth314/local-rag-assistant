import Foundation

/// The one set of call machinery in the process, wired exactly once.
///
/// ## Why this must be a singleton
///
/// `CallService.init` registers a live `CXProvider` and makes itself the
/// delegate. SwiftUI re-runs a view's `init` on any parent update, and
/// `@StateObject` only protects the *stored* instance — every re-init still
/// constructed a throwaway `CallService`, each registering another provider
/// and capturing the delegate callbacks.
///
/// The result was a haunted call: CallKit delivered actions to a phantom
/// instance, whose session ran the whole conversation audibly — while the
/// instance the UI observed sat in `.dialing` forever. Audio worked, the
/// transcript never appeared, and mute from the system UI toggled an object
/// nothing was looking at. Every symptom traced back to construction-per-init.
///
/// Constructing here, once, is the fix. Views borrow these objects; nothing
/// about a view's lifecycle can create call machinery again.
@MainActor
final class CallStack {

    static let shared = CallStack()

    let call: CallService
    let session: CallSessionModel
    let push: VoIPPushService

    private init() {
        let call = CallService()
        // Placeholder until `configure` — replaced before any call can exist,
        // because RootView configures in its init and nothing can dial sooner.
        let session = CallSessionModel(service: DemoATARUService())

        // The system owns the audio route, so the conversation starts when
        // CallKit says the session is live — not when the call connects.
        call.onAudioActivated = { [weak session] in session?.begin() }
        call.onAudioDeactivated = { [weak session] in session?.end() }
        // CallKit's mute action is bookkeeping; this is what stops the mic.
        call.onMuteChanged = { [weak session] muted in session?.setMuted(muted) }
        // "That will be all" → goodbye → hang up, through the same CallKit
        // path as the End button.
        session.onFarewell = { [weak call] in call?.end() }

        self.call = call
        self.session = session
        // The push registry must exist before a push can arrive.
        self.push = VoIPPushService(call: call)
    }

    private var configuredService: ATARUService?

    /// Points the stack at the current backend.
    ///
    /// Idempotent per service instance, because it is called from a view init
    /// that re-runs freely. `CallSessionModel.update` tears down the voice
    /// stream, so it must only happen when the service really changed.
    func configure(service: ATARUService) {
        guard configuredService !== service else { return }
        configuredService = service
        session.update(service: service)
        push.update(service: service)
    }
}
