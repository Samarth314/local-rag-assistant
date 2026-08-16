import Intents
import SwiftUI

/// The app's one screen, and everything that can take it over.
///
/// There is no tab bar and no visible launcher. Ask is the root, every other
/// destination arrives as a layer over it, and the way between them is a thumb
/// held anywhere on the glass — see `RadialPressMenu`. What is left is the
/// content and nothing else.
///
/// The layering is load-bearing, bottom to top: the root screen, a tile
/// screen, the launcher, the call. The launcher has to outrank the tile
/// screen or it stops working on most of the app; the call outranks
/// everything because a conversation in progress owns the surface.
struct RootView: View {
    @EnvironmentObject private var state: AppState
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

    // THE ROOT IS ASK, AND ONLY ASK.
    //
    // There used to be a `Tab` enum with two cases, `ask` and `library`, and
    // `open(tile:)` intercepted `.documents` into the second one. That made
    // the document library the one destination in `HomeTile` that was not a
    // tile screen: no host chrome, and - the part that was actually wrong -
    // no swipe to close, because closing it meant switching a root rather
    // than dismissing a layer. There was nothing to dismiss, so the page had
    // no way out but the launcher.
    //
    // It is a tile now like everything else. `presentedTile` is the whole of
    // the routing state, and every destination behaves identically.

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
            VoiceView(composerActive: $isComposerActive)
            // Read from the content only, and applied to a sibling: a
            // preference consumed by something that could resize its own
            // producer is how layout loops start.
            .onPreferenceChange(PressExclusionKey.self) { pressExclusions = $0 }
            .ataruBackdrop()
            // VoiceOver reaches SIBLINGS IN A ZSTACK, not just the top one.
            // Nothing about drawing a tile screen or the call over Ask removed
            // Ask from the accessibility tree, so a swipe from the last
            // element of the layer on top carried straight on into the orb,
            // the composer and the transcript underneath - controls the user
            // cannot see and, in the call's case, must not reach. Marking the
            // top layer `.isModal` is the stated SwiftUI answer and is not
            // reliable across sibling layers of a ZStack; hiding what is
            // underneath is. Both are applied: the trait for the platforms
            // that honour it, the hiding for the guarantee.
            .accessibilityHidden(isAskCovered)

            // The app's destinations, as named actions, always.
            //
            // They used to hang off the orb, and the orb is the first thing
            // AskMetrics deletes when the screen runs out of height. On a
            // small phone at an accessibility text size with the keyboard up
            // the orb is zeroed, so the actions went with it and the app had
            // no navigation for VoiceOver AT ALL: no dial (it takes its
            // touches from a window recogniser and is `accessibilityHidden`),
            // no tab bar, no destinations menu. This element is not sized by
            // anything, so nothing can take it away.
            DestinationActions(open: open(tile:))
                .accessibilityHidden(isAskCovered)
                .zIndex(0.5)

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
            // A crossfade, NOT a slide up from the bottom.
            //
            // The slide is what he saw as "a rectangle of a different shade
            // sweeping from the bottom of the page to the top": this host
            // painted a flat colour where everything behind it paints the
            // backdrop gradient, and it carried that mismatch up the screen
            // over 0.24s on every single tile open. Worse, the host's own
            // backdrop is anchored to the moving frame, so mid-slide two
            // copies of the same gradient sat offset from each other and the
            // seam between them was the moving edge.
            //
            // Fading has no edge to sweep. It also composites cleanly now that
            // TileScreenHost paints the same backdrop as the root: the two
            // gradients are identical AND aligned, so the background is
            // completely still through the transition and only the content
            // crossfades, which is the only part that is actually changing.
            //
            // The call layers below keep their slide on purpose - a call bar
            // arriving from the bottom edge is a thing entering from off
            // screen, which is what that motion is for.
            if let tile = presentedTile {
                TileScreenHost(tile: tile) { close() }
                    .environmentObject(state)
                    // Asymmetric on purpose. Arriving is a crossfade, which is
                    // what stopped the old slide dragging a mismatched
                    // rectangle up the screen. Leaving is a dissolve: the page
                    // has usually just been thrown downward by a thumb, and
                    // cutting it at that moment is what read as abrupt.
                    .transition(.asymmetric(insertion: .opacity,
                                            removal: .tileDissolve))
                    .zIndex(1.5)
                    // Modal over Ask, and itself hidden once a call takes the
                    // whole surface. A MINIMISED call is deliberately not a
                    // cover: the bar exists so the app underneath stays usable.
                    .accessibilityAddTraits(.isModal)
                    .accessibilityHidden(isCallModal)
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
                current: presentedTile ?? .assistant,
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
                        // A conversation in progress owns the surface, for
                        // VoiceOver as much as for a thumb.
                        .accessibilityAddTraits(.isModal)
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
        // Not `await refreshConnection()` any more. That was the single probe
        // that ran before the tailnet was up and then published its negative
        // forever; this starts the retry ladder instead. See
        // `AppState.probeConnection`.
        .task {
            state.probeConnection()
            // UI suite only, and nil in every other run: XCUITest can drive
            // neither the launcher nor the orb's accessibility actions, so a
            // test that needs a tile page is put on it. See RuntimeMode.
            if let tile = RuntimeMode.startTile { open(tile: tile) }
        }
        // Demo ⇄ Live flips after launch. Keyed on the generation counter, NOT
        // on `ObjectIdentifier(state.service)`: a replacement service can land
        // on the freed address of the one it replaced, which reads as no
        // change at all and leaves every one of these pointed at the old
        // backend. See `AppState.serviceGeneration`.
        .task(id: state.serviceGeneration) {
            CallStack.shared.configure(service: state.service)
            // Transcription goes to this server too, so it has to follow a
            // Demo/Live flip along with everything else in here.
            SpeechDictation.sharedService = state.service
            // The notification token follows the backend from `AppState`
            // itself now - see `rebuildService` - so it is not repeated here.
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

    /// True while a call has the whole surface. A minimised call is a bar over
    /// a usable app, which is the opposite of a modal.
    private var isCallModal: Bool { call.state.isLive && !isCallMinimized }

    /// True when a layer is drawn over the Ask screen. Drives nothing visual -
    /// the ZStack already handles that - only what VoiceOver may reach.
    private var isAskCovered: Bool { presentedTile != nil || isCallModal }

    /// The one routing table: Ask is the root, everything else is a layer.
    ///
    /// Every path sets `presentedTile`, including to nil — the launcher works
    /// from inside a tile screen now, so "go to Ask" arriving while Finance
    /// is up has to take Finance down.
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

        // Media hands straight over to Swiftfin when it is installed, without
        // a screen of ours in between. A video server deserves its own player,
        // and the status card this replaces was advice with no way to act on
        // it. Not installed - or the query scheme missing from Info.plist,
        // which looks identical - falls through to that card, which now says
        // so. Done outside the animation: there is nothing of ours to animate,
        // and the app is about to leave the foreground.
        if tile == .media, ExternalApp.swiftfin.open() { return }

        withAnimation(.easeInOut(duration: 0.24)) {
            presentedTile = tile == .assistant ? nil : tile
        }
    }

    private func close() {
        // Quicker than the open. A page being put away should be gone the
        // moment the decision is made; a page arriving can afford to arrive.
        withAnimation(.easeOut(duration: 0.22)) { presentedTile = nil }
    }
}

/// EVERY DESTINATION, AS NAMED ACTIONS, FOR ANYONE WHO CANNOT PRESS AND SWEEP.
///
/// The radial launcher takes its touches from a recogniser on the window and
/// never participates in hit-testing, so VoiceOver and Switch Control cannot
/// reach it at all. With no tab bar and no destinations menu, these actions are
/// the whole of the app's navigation for those users. They are the floor, not a
/// nicety.
///
/// ## Why they live here rather than on the orb
///
/// They were attached to the Ask orb, on the sound reasoning that it is the one
/// element a VoiceOver user is certain to land on. But the orb is also the
/// first thing `AskMetrics` sacrifices when the screen runs out of height, and
/// it is deleted outright below `minimumOrb`. Small phone, accessibility text
/// size, keyboard up: no orb, therefore no actions, therefore no way off the
/// screen. The app's navigation floor cannot be a child of a layout decision.
///
/// ## Why an invisible element rather than a control
///
/// The empty navigation bar is a deliberate design position - the launcher is
/// THE launcher - and this restores the floor without putting a glyph back on
/// the front screen. It never takes a touch, so a sighted user cannot land on
/// it; it has a label and custom actions, so VoiceOver can. Top-leading and
/// 44pt square so it also answers to touch exploration around the corner where
/// a control would have been.
private struct DestinationActions: View {
    let open: (HomeTile) -> Void

    var body: some View {
        Color.clear
            .frame(width: Theme.minHitTarget, height: Theme.minHitTarget)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .allowsHitTesting(false)
            .accessibilityElement()
            .accessibilityLabel("Destinations")
            .accessibilityHint("Use the actions rotor to open another screen.")
            // Built from `HomeTile.allCases`, so a tile added to the enum
            // appears here and in the dial together and neither can fall
            // behind the other.
            .accessibilityActions {
                ForEach(HomeTile.allCases.filter { $0 != .assistant }) { tile in
                    Button("Open \(tile.title)") { open(tile) }
                }
            }
    }
}

#Preview {
    let state = AppState()
    RootView(state: state).environmentObject(state)
}
