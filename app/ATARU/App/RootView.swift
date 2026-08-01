import Intents
import SwiftUI

/// Two tabs, because the app does two things: ask, and browse what it asked of.
///
/// The original nine-feature dashboard was deliberately cut back to this. A
/// tab bar full of destinations the backend cannot yet fill would be a worse
/// product than two that work.
struct RootView: View {
    @EnvironmentObject private var state: AppState
    @State private var selection: Tab = .ask

    @StateObject private var call: CallService
    @StateObject private var session: CallSessionModel
    @StateObject private var push: VoIPPushService

    init() {
        // Everything is wired here rather than in `.onAppear`, because a call
        // can arrive before the view appears: tapping ATARU in Recents cold
        // launches the app straight into an intent, and a VoIP push wakes it
        // with no view lifecycle at all. Wiring on appear leaves a window where
        // the call connects and nothing is listening for the audio session.
        let call = CallService()
        // Service is replaced in `.task` once the environment's is known.
        let session = CallSessionModel(service: DemoATARUService())

        // The system owns the audio route, so the conversation starts when
        // CallKit says the session is live — not when the call connects.
        call.onAudioActivated = { [weak session] in session?.begin() }
        call.onAudioDeactivated = { [weak session] in session?.end() }

        _call = StateObject(wrappedValue: call)
        _session = StateObject(wrappedValue: session)
        // The push registry must exist before a push can arrive.
        _push = StateObject(wrappedValue: VoIPPushService(call: call))
    }

    enum Tab: Hashable { case ask, library }

    /// Two tabs, plus the call.
    ///
    /// CallKit still owns the call *outside* the app — lock screen, banner, the
    /// green pill — and answering there needs nothing from us. But when the app
    /// is on screen during a call, a tab bar says nothing about the fact that a
    /// conversation is audibly in progress. `CallSessionView` is what the app
    /// shows for the duration.
    ///
    /// A layer rather than a `fullScreenCover`: a cover competes with whatever
    /// sheet or navigation push is already up, and a live call should never
    /// lose that race.
    var body: some View {
        ZStack {
            TabView(selection: $selection) {
                VoiceView()
                    .tabItem { Label("Ask", systemImage: "waveform") }
                    .tag(Tab.ask)

                DocumentsView()
                    .tabItem { Label("Library", systemImage: "tray.full") }
                    .tag(Tab.library)
            }
            .ataruBackdrop()

            if call.state.isLive {
                CallSessionView(call: call, session: session)
                    .zIndex(1)
            }
        }
        // The entry point for calling ATARU is a contact card, the Phone app or
        // Siri — not a button in here. This is where that request lands.
        // Warm path: the app was already running when the tap happened. One
        // modifier per activity type — the modifier matches a single type, so a
        // request arriving as the legacy one would otherwise reach nothing.
        .onContinueUserActivity(NSStringFromClass(INStartCallIntent.self)) { activity in
            guard CallIntent.isCallRequest(activity) else { return }
            call.call()
        }
        .onContinueUserActivity("INStartAudioCallIntent") { _ in
            call.call()
        }
        // Cold path: the tap launched the app, and the activity reached the
        // delegate before this view existed. Draining it here is what makes a
        // Recents tap dial immediately rather than just opening the app and
        // waiting to be told what to do.
        .task {
            if PendingCallRequest.take() { call.call() }
        }
        .task { await state.refreshConnection() }
        .task(id: ObjectIdentifier(state.service)) {
            session.update(service: state.service)
            // Re-registers the push token against whichever backend is now
            // selected. A token registered with Demo reaches nothing.
            push.update(service: state.service)
        }
        .environmentObject(call)
    }
}

#Preview {
    RootView().environmentObject(AppState())
}
