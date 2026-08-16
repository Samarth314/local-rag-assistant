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
        // An interruption HOLDS the conversation; it does not end it. Wired to
        // `setInterrupted` rather than to `end`/`begin` for that reason: a
        // 7am alarm landing on the 7am call must not hang it up, and a loop
        // restarted through `begin` would greet him a second time.
        call.onAudioInterrupted = { [weak session] in session?.setInterrupted(true) }
        call.onAudioResumed = { [weak session] in session?.setInterrupted(false) }
        // "That will be all" → goodbye → hang up, through the same CallKit
        // path as the End button.
        session.onFarewell = { [weak call] in call?.end() }

        self.call = call
        self.session = session
        // The push registry must exist before a push can arrive.
        self.push = VoIPPushService(call: call)
    }

    /// The service this stack is pointed at.
    ///
    /// STRONG on purpose, and load-bearing. `RootView` used to compare
    /// `ObjectIdentifier(state.service)` without holding the object, so a
    /// replacement service could land on the freed address of the one it
    /// replaced and read as no change at all - which is how a saved token left
    /// the morning call registered nowhere. Retaining the old service here
    /// keeps its address occupied, so `!==` cannot be fooled the same way.
    private var configuredService: ATARUService?
    /// `AppState.serviceGeneration` as of the last configure, when a caller
    /// bothers to pass it. Monotonic, so it cannot alias the way an address
    /// can.
    private var configuredGeneration: Int?

    /// Points the stack at the current backend.
    ///
    /// Idempotent per backend, because it is called from a view init that
    /// re-runs freely. `CallSessionModel.update` tears down the voice stream
    /// and `push.update` re-uploads the VoIP token, so neither may happen on
    /// an ordinary re-render.
    ///
    /// - Parameter generation: `AppState.serviceGeneration`. Preferred over
    ///   object identity when supplied - it is the counter every other surface
    ///   in the app keys on, and unlike an address it is never reused. Callers
    ///   that omit it fall back to the identity check above, which is sound
    ///   only because `configuredService` is a strong reference.
    func configure(service: ATARUService, generation: Int? = nil) {
        if let generation {
            guard configuredGeneration != generation else { return }
            configuredGeneration = generation
        } else {
            guard configuredService !== service else { return }
        }
        configuredService = service
        session.update(service: service)
        push.update(service: service)
    }
}
