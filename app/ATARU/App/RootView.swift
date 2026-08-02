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
    /// Owned here so the app behind the launcher can be dimmed while its fan
    /// is open.
    @State private var isMenuOpen = false
    /// The web page a tile opened, if any. Tiles without a native screen show
    /// the real page rather than nothing.
    @State private var webTile: URL?

    // Borrowed from CallStack, never constructed here. A view's init re-runs
    // on any parent update, and constructing call machinery per-init is what
    // produced the phantom-call bug: CallKit's delegate landed on a throwaway
    // instance whose session ran the conversation audibly while the observed
    // instance sat in `.dialing` — audio fine, no transcript, mute desynced.
    // See CallStack for the full story.
    @ObservedObject private var call: CallService
    @ObservedObject private var session: CallSessionModel

    init(state: AppState) {
        let stack = CallStack.shared
        // Configured here rather than in `.task`, because a Recents tap dials
        // during the first render — a session still pointed at Demo at that
        // moment answers the whole call from fixtures. AppState resolves Live
        // synchronously from persisted configuration, so this is safe cold.
        stack.configure(service: state.service)
        call = stack.call
        session = stack.session
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

            // The launcher: one circle at rest, a fan of destinations while a
            // thumb is held on it. Sits above the tabs rather than inside a
            // screen, because it navigates between them.
            // Dims the app behind the fan, and takes the tap that dismisses
            // it. Drawn as a sibling because a scrim from inside the menu
            // could not reach past the menu's own bounds.
            if isMenuOpen {
                Color.black.opacity(0.5)
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .zIndex(1.5)
                    .onTapGesture {
                        withAnimation(.easeOut(duration: 0.2)) { isMenuOpen = false }
                    }
            }

            if !call.state.isLive {
                // Full-screen layer; the menu anchors itself to the bottom-right
                // corner and paints no background, so it costs nothing when
                // closed.
                RadialTileMenu(isOpen: $isMenuOpen) { tile in
                    switch tile.destination {
                    case .ask: selection = .ask
                    case .library: selection = .library
                    case .web(let url): webTile = url
                    }
                }
                .zIndex(2)
            }

            if call.state.isLive {
                if isCallMinimized {
                    // Floats over the app rather than pushing it down, so
                    // minimising does not reflow whatever you minimised it to
                    // go and look at. Full-width, just above the tab bar.
                    VStack {
                        Spacer()
                        MinimizedCallBar(call: call, session: session) {
                            withAnimation(.easeInOut(duration: 0.28)) {
                                isCallMinimized = false
                            }
                        }
                        .padding(.horizontal, Theme.Space.xs)
                        // Clears the tab bar, so it never sits on top of Ask
                        // and Library.
                        .padding(.bottom, 54)
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
        // Demo ⇄ Live flips after launch. Also re-registers the push token —
        // a token registered with Demo reaches nothing.
        .task(id: ObjectIdentifier(state.service)) {
            CallStack.shared.configure(service: state.service)
            // Warm the name roster here, where waiting costs nothing. Fetching
            // it when the talk button goes down delayed the microphone past
            // the user's release.
            if let names = try? await state.service.vocabulary(), !names.isEmpty {
                SpeechDictation.sharedVocabulary = names
            }
        }
        .sheet(item: $webTile) { url in
            WebTileView(url: url).ignoresSafeArea()
        }
        .environmentObject(call)
    }
}

#Preview {
    let state = AppState()
    RootView(state: state).environmentObject(state)
}
