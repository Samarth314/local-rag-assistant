import Intents
import SwiftUI

/// The app's one screen, and everything that can take it over.
///
/// There is no tab bar and no visible launcher. Three root screens swap in
/// place, every other destination arrives as a sheet, and the way between them
/// is a thumb held anywhere on the glass — see `RadialPressMenu`. What is left
/// is the content and nothing else.
struct RootView: View {
    @EnvironmentObject private var state: AppState
    @State private var selection: Tab = .ask
    /// Lives here rather than in the call screen: a minimised call still exists,
    /// so the state has to outlive that view being torn down.
    @State private var isCallMinimized = false
    /// Rects the launcher's long press must keep its hands off, reported up
    /// from whatever is on screen. The orb is the one that matters: holding it
    /// is how you talk to ATARU.
    @State private var pressExclusions: [CGRect] = []
    /// The native tile screen currently presented, if any. Every tile is
    /// native now - the grid and the radial dial are two ways of opening the
    /// same set, and nothing routes to a web page.
    @State private var presentedTile: HomeTile?

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

    enum Tab: Hashable { case ask, tiles, library }

    /// True while the Ask composer owns the keyboard. Reported up from
    /// VoiceView so the radial launcher can get out of the way - the dial
    /// used to float on top of the keyboard and the composer.
    @State private var isComposerActive = false

    /// The current screen, the launcher over it, and the call over everything.
    ///
    /// CallKit still owns the call *outside* the app — lock screen, banner, the
    /// green pill — and answering there needs nothing from us. But when the app
    /// is on screen during a call, nothing in the ordinary chrome says a
    /// conversation is audibly in progress. `CallSessionView` is what the app
    /// shows for the duration.
    ///
    /// A layer rather than a `fullScreenCover`: a cover competes with whatever
    /// sheet or navigation push is already up, and a live call should never
    /// lose that race.
    var body: some View {
        ZStack {
            // No tab bar, and no launcher either — nothing permanent at the
            // bottom at all. Every destination is a held thumb away, so the
            // screen belongs entirely to its content and the app looks like
            // almost nothing until someone reaches for it.
            Group {
                switch selection {
                case .ask:     VoiceView(composerActive: $isComposerActive)
                case .tiles:   TilesView(onOpen: open(tile:))
                case .library: DocumentsView()
                }
            }
            // Read from the content only, and applied to a sibling: a
            // preference consumed by something that could resize its own
            // producer is how layout loops start.
            .onPreferenceChange(PressExclusionKey.self) { pressExclusions = $0 }
            .ataruBackdrop()

            // The launcher. Invisible and untouchable until a press is held,
            // which is why it can sit over the entire app: it takes its
            // touches from a recogniser on the window rather than from the
            // view hierarchy, so nothing underneath loses a tap to it.
            //
            // Off during a call — the call screen owns the whole surface, and
            // its own gestures are the ones that should answer — off while the
            // keyboard is up, where a hold means text selection, and off
            // behind a presented tile. That last one is not cosmetic: a sheet
            // is a separate presentation but the same *window*, so the
            // recogniser still fires under it while this layer draws behind
            // it. The fan would be invisible and the release would silently
            // change the screen the sheet is covering.
            RadialPressMenu(
                isEnabled: !call.state.isLive && !isComposerActive && presentedTile == nil,
                exclusions: pressExclusions,
                onSelect: open(tile:)
            )
            .zIndex(2)

            if call.state.isLive {
                if isCallMinimized {
                    // Floats over the app rather than pushing it down, so
                    // minimising does not reflow whatever you minimised it to
                    // go and look at. Full-width, along the bottom.
                    VStack {
                        Spacer()
                        MinimizedCallBar(call: call, session: session) {
                            withAnimation(.easeInOut(duration: 0.28)) {
                                isCallMinimized = false
                            }
                        }
                        .padding(.horizontal, Theme.Space.xs)
                        // Was 54 to clear the tab bar. There is no tab bar and
                        // no launcher down here any more, so the bar can sit
                        // where it belongs.
                        .padding(.bottom, Theme.Space.xs)
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
        .sheet(item: $presentedTile) { tile in
            TileScreenHost(tile: tile)
                .environmentObject(state)
        }
        .environmentObject(call)
        // Lets a navigation bar anywhere in the app route without being handed
        // a closure through three initialisers. See TileDestinationsMenu.
        .environment(\.openTile, open(tile:))
    }

    /// One routing table for both launchers: tabs for the two tab-native
    /// screens, a presented native screen for everything else.
    private func open(tile: HomeTile) {
        switch tile {
        case .assistant: selection = .ask
        case .documents: selection = .library
        default: presentedTile = tile
        }
    }
}

#Preview {
    let state = AppState()
    RootView(state: state).environmentObject(state)
}
