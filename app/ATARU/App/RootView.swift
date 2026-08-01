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
        // Replaced in `.task` once the environment's service is known.
        _session = StateObject(wrappedValue: CallSessionModel(service: DemoATARUService()))
        // The push registry has to exist before a push can arrive, so it is
        // built with the view rather than lazily on first use.
        let call = CallService()
        _call = StateObject(wrappedValue: call)
        _push = StateObject(wrappedValue: VoIPPushService(call: call))
    }

    enum Tab: Hashable { case ask, library }

    /// The app deliberately has no call UI of its own.
    ///
    /// CallKit draws the call — lock screen, banner, the green pill in the
    /// status bar, mute and hang up. Duplicating that in-app was solving a
    /// problem that does not exist: with ATARU open you would simply use Ask
    /// rather than phone something on the same device. Calling earns its place
    /// only when the app is closed, and that is precisely when the system
    /// already provides the whole interface.
    ///
    /// So this view stays a plain two-tab app. `CallService` runs the call and
    /// `CallSessionModel` runs the conversation, both without a screen.
    var body: some View {
        TabView(selection: $selection) {
            VoiceView()
                .tabItem { Label("Ask", systemImage: "waveform") }
                .tag(Tab.ask)

            DocumentsView()
                .tabItem { Label("Library", systemImage: "tray.full") }
                .tag(Tab.library)
        }
        .ataruBackdrop()
        // The entry point for calling ATARU is a contact card, the Phone app or
        // Siri — not a button in here. This is where that request lands.
        .onContinueUserActivity(NSStringFromClass(INStartCallIntent.self)) { activity in
            guard CallIntent.isCallRequest(activity) else { return }
            call.call()
        }
        .task { await state.refreshConnection() }
        .task(id: ObjectIdentifier(state.service)) {
            session.update(service: state.service)
            // Re-registers the push token against whichever backend is now
            // selected. A token registered with Demo reaches nothing.
            push.update(service: state.service)
        }
        .onAppear {
            // The system owns the audio route, so the conversation starts when
            // CallKit says the session is live — not when the call connects.
            call.onAudioActivated = { session.begin() }
            call.onAudioDeactivated = { session.end() }
        }
        .environmentObject(call)
    }
}

#Preview {
    RootView().environmentObject(AppState())
}
