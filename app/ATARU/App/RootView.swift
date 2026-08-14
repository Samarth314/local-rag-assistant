import Intents
import SwiftUI

/// The app's one screen, and everything that can take it over.
///
/// There is no tab bar and no visible launcher. Two root screens swap in
/// place, every other destination arrives as a layer over them, and the way
/// between them is a thumb held anywhere on the glass — see `RadialPressMenu`.
/// What is left is the content and nothing else.
///
/// The layering is load-bearing, bottom to top: the root screen, a tile
/// screen, the launcher, the call. The launcher has to outrank the tile
/// screen or it stops working on most of the app; the call outranks
/// everything because a conversation in progress owns the surface.
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
    /// native now - the radial dial and the accessibility menu are two ways of
    /// opening the same set, and nothing routes to a web page.
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

    /// The two screens that are roots rather than layers. Everything else in
    /// `HomeTile` arrives as a tile screen over one of these.
    ///
    /// There was a third, `tiles`, backing a scrollable grid of every
    /// destination. The radial launcher replaced it and nothing ever assigned
    /// the case again, so the grid had been unreachable since the tab bar was
    /// dropped - see `TileDestinationsMenu` for the accessible way in.
    enum Tab: Hashable { case ask, library }

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
                case .library: DocumentsView()
                }
            }
            // Read from the content only, and applied to a sibling: a
            // preference consumed by something that could resize its own
            // producer is how layout loops start.
            .onPreferenceChange(PressExclusionKey.self) { pressExclusions = $0 }
            .ataruBackdrop()

            // A tile screen, drawn in this stack rather than presented as a
            // sheet.
            //
            // A sheet outranks every layer this view owns, the launcher
            // included — which is why holding a thumb on Finance or Status
            // used to do nothing at all, and why the launcher had to be
            // switched off whenever one was up. A launcher that stops working
            // on most of the app's pages is not the only way between them, so
            // the presentation gave way instead. Here it is just a layer, the
            // launcher stays above it, and every page behaves the same.
            if let tile = presentedTile {
                TileScreenHost(tile: tile) { close() }
                    .environmentObject(state)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(1.5)
            }

            // The launcher. Invisible and untouchable until a press is held,
            // which is why it can sit over the entire app: it takes its
            // touches from a recogniser on the window rather than from the
            // view hierarchy, so nothing underneath loses a tap to it.
            //
            // Off during a call — the call screen owns the whole surface and
            // its own gestures are the ones that should answer — and off while
            // the keyboard is up, where a hold means text selection. On
            // everywhere else, including on top of a tile screen, which passes
            // itself as `current` so the fan never offers the page you are
            // already reading.
            RadialPressMenu(
                isEnabled: !call.state.isLive && !isComposerActive,
                // Only what is actually on top gets to claim a hold. These
                // are published by the root screen, which stays mounted
                // underneath a tile — so leaving them in place meant the Ask
                // orb's rect, a 260pt band across the middle of the screen,
                // silently killed the launcher on every tile page. A tile
                // screen has nothing a hold means something else on.
                exclusions: presentedTile == nil ? pressExclusions : [],
                current: presentedTile ?? currentTile,
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
                    .zIndex(3)
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
                        .zIndex(3)
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
            // Transcription goes to this server too, so it has to follow a
            // Demo/Live flip along with everything else in here.
            SpeechDictation.sharedService = state.service
            // Warm the name roster here, where waiting costs nothing. Fetching
            // it when the talk button goes down delayed the microphone past
            // the user's release.
            if let names = try? await state.service.vocabulary(), !names.isEmpty {
                SpeechDictation.sharedVocabulary = names
            }
        }
        .environmentObject(call)
        // Lets a navigation bar anywhere in the app route without being handed
        // a closure through three initialisers. See TileDestinationsMenu.
        .environment(\.openTile, open(tile:))
    }

    /// The tile the current screen already is, so the launcher can leave it
    /// out.
    private var currentTile: HomeTile? {
        switch selection {
        case .ask:     return .assistant
        case .library: return .documents
        }
    }

    /// One routing table for both launchers: root screens for the two that
    /// are one, a tile layer for everything else.
    ///
    /// Every path sets `presentedTile`, including to nil — the launcher works
    /// from inside a tile screen now, so "go to Ask" arriving while Finance
    /// is up has to take Finance down as well as change what is behind it.
    private func open(tile: HomeTile) {
        // A tile screen is a LAYER over the root, not a presentation, so
        // VoiceView stays mounted underneath with its focus intact. Nothing
        // resigned it, so navigating away from a focused composer left the
        // keyboard drawn over the destination page - and, because the radial
        // launcher is disabled while the composer is active, left the app's
        // primary navigation dead on the page you had just opened.
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                        to: nil, from: nil, for: nil)
        isComposerActive = false
        withAnimation(.easeInOut(duration: 0.24)) {
            switch tile {
            case .assistant:
                presentedTile = nil
                selection = .ask
            case .documents:
                presentedTile = nil
                selection = .library
            default:
                presentedTile = tile
            }
        }
    }

    private func close() {
        withAnimation(.easeInOut(duration: 0.24)) { presentedTile = nil }
    }
}

#Preview {
    let state = AppState()
    RootView(state: state).environmentObject(state)
}
