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
    /// Lives here rather than in the call screen: a minimised call still exists,
    /// so the state has to outlive that view being torn down.
    @State private var isCallMinimized = false

    @StateObject private var call: CallService
    @StateObject private var session: CallSessionModel
    @StateObject private var push: VoIPPushService

    init(state: AppState) {
        // Everything is wired here rather than in `.onAppear`, because a call
        // can arrive before the view appears: tapping ATARU in Recents cold
        // launches the app straight into an intent, and a VoIP push wakes it
        // with no view lifecycle at all. Wiring on appear leaves a window where
        // the call connects and nothing is listening for the audio session.
        let call = CallService()
        // Born with the REAL service, not a placeholder: a Recents tap dials
        // during the first render, before any `.task` runs - a session that
        // starts as Demo and is swapped later loses that race and answers the
        // whole call from fixtures. AppState resolves Live synchronously from
        // the persisted configuration, so this is safe at cold launch.
        let session = CallSessionModel(service: state.service)

        // The system owns the audio route, so the conversation starts when
        // CallKit says the session is live — not when the call connects.
        call.onAudioActivated = { [weak session] in session?.begin() }
        call.onAudioDeactivated = { [weak session] in session?.end() }
        // CallKit's mute action is bookkeeping; this is what stops the mic.
        call.onMuteChanged = { [weak session] muted in session?.setMuted(muted) }
        // "That will be all" → goodbye → hang up, through the same CallKit
        // path as the End button.
        session.onFarewell = { [weak call] in call?.end() }

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
                if isCallMinimized {
                    // Floats over the app rather than pushing it down, so
                    // minimising does not reflow whatever you minimised it to
                    // go and look at. Bottom-right, clear of the tab bar.
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            MinimizedCallBar(call: call, session: session) {
                                withAnimation(.easeInOut(duration: 0.28)) {
                                    isCallMinimized = false
                                }
                            }
                        }
                        .padding(.horizontal, Theme.Space.screen)
                        // Clears the tab bar, so it never sits on top of Ask
                        // and Library.
                        .padding(.bottom, 58)
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(1)
                    // Two fingers up restores the call from anywhere in the app.
                    .twoFingerSwipe(
                        up: {
                            withAnimation(.easeInOut(duration: 0.28)) {
                                isCallMinimized = false
                            }
                        },
                        down: {}
                    )
                } else {
                    CallSessionView(call: call, session: session,
                                    isMinimized: $isCallMinimized)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .zIndex(1)
                }
            }
        }
        // A finished call always comes back expanded. Restoring minimised would
        // hide the next call behind a bar the user has to notice and tap.
        .onChange(of: call.state.isLive) { _, isLive in
            if !isLive { isCallMinimized = false }
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
    let state = AppState()
    RootView(state: state).environmentObject(state)
}
