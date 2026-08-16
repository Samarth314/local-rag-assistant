import SwiftUI

/// Ask ATARU out loud.
///
/// Hold to speak, release to send. Holding rather than tapping is deliberate:
/// it makes the end of the question unambiguous, so nothing has to guess when
/// the user stopped talking, and releasing early is a natural cancel.
struct VoiceView: View {
    @EnvironmentObject private var state: AppState
    @StateObject private var model: VoiceViewModel

    /// The keyboard's actual owner. Everything that dismisses the keyboard -
    /// Done, submit, tapping the backdrop, dragging the transcript - goes
    /// through this one flag; before it existed nothing in the app could
    /// resign the field and the keyboard stayed up forever.
    @FocusState private var composerFocused: Bool
    /// A press is already opening the microphone. See the orb's drag gesture:
    /// `onChanged` fires per touch report and `beginListening` is async, so
    /// without this a single press starts it several times over.
    @State private var isStartingListen = false
    /// Measured, not assumed - see KeyboardInset for why the automatic
    /// avoidance cannot reach this screen.
    @StateObject private var keyboard = KeyboardInset()
    /// Reported upward so RootView can hide the radial launcher while the
    /// user is typing - the dial used to float on top of the composer.
    @Binding private var composerActive: Bool
    @Environment(\.scenePhase) private var scenePhase
    /// "I'm up" - see MorningConfirm. Lives here as well as on the call screen
    /// because a call he half-answered may already be hung up, and the app is
    /// the other place a half-awake hand goes.
    @StateObject private var morning = MorningConfirmModel()
    /// The user's text size, as a multiplier. Everything on this screen that
    /// has a fixed height has to grow with it or it clips its own contents at
    /// the accessibility sizes.
    @ScaledMetric(relativeTo: .body) private var textScale: CGFloat = 1

    init(composerActive: Binding<Bool> = .constant(false)) {
        // Replaced in `.task` once the environment's service is known; a
        // StateObject cannot read the environment during init.
        _model = StateObject(wrappedValue: VoiceViewModel(service: DemoATARUService()))
        _composerActive = composerActive
    }

    var body: some View {
        NavigationStack {
            ZStack {
                // AtaruBackdrop, not `Ataru.backdrop` - the raw gradient is
                // anchored to whatever frame paints it. See Backdrop.swift.
                AtaruBackdrop(surface: "ask")

                // Tap anywhere off the controls to put the keyboard away.
                //
                // Always in the hierarchy, switched on by hit-testing rather
                // than by an `if`. Inserting a sibling into this ZStack at the
                // moment the field takes focus is a structural change
                // mid-first-responder, and SwiftUI answers it by dropping the
                // responder: the keyboard rose and vanished in the same frame,
                // which reads as a text field that simply does not work.
                // Changing a modifier on a view that is already there does not
                // touch the hierarchy, so focus survives.
                //
                // It sits UNDER the content, which is why it was never enough
                // on its own: the orb, the status line and the answer cards
                // are all hit-testable, so every tap "above the keyboard"
                // landed on one of them and never reached this layer. It now
                // only catches taps that miss everything - margins and gutters
                // - while `.dismissesKeyboard(when:)` handles the content
                // itself. Kept because those margins are real.
                Color.clear
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
                    .allowsHitTesting(composerFocused)
                    .onTapGesture { composerFocused = false }

                // THE COMPOSER MUST STAY ABOVE THE KEYBOARD, both ways up.
                //
                // This column is given an explicit height because it is
                // Spacers and fixed blocks and has to fill the screen rather
                // than settle at its natural size. But SwiftUI's automatic
                // keyboard avoidance works by shrinking the SAFE AREA, and a
                // view with an explicit height does not care what the safe
                // area does - so the column stayed full-screen tall and the
                // keyboard was simply drawn over the bottom of it, composer
                // included. That is the "I have no idea what I am typing" bug,
                // and it was the same in landscape, where there is far less
                // height to lose.
                //
                // So this opts out of the implicit behaviour that was already
                // being overridden, and subtracts a measured keyboard overlap
                // instead. `geo` then stays stable and orientation-correct,
                // and the height change is animated with the keyboard's OWN
                // duration, so the composer travels up with it rather than
                // arriving after it.
                GeometryReader { geo in
                    // THE HEIGHT THE KEYBOARD LEFT BEHIND, and what fits in
                    // it. Shrinking the frame was never enough on its own -
                    // the fixed blocks inside it added up to more than the
                    // remaining height, a frame does not clip, and the bottom
                    // of the column (the composer) was drawn under the
                    // keyboard. AskMetrics decides what yields. See there.
                    let available = max(160, geo.size.height - keyboard.overlap)
                    let isLandscape = geo.size.width > geo.size.height
                    let metrics = isLandscape
                        ? AskMetrics.landscape(available: available,
                                               focused: composerFocused,
                                               scale: textScale)
                        : AskMetrics.portrait(available: available,
                                              focused: composerFocused,
                                              hasExchanges: !model.exchanges.isEmpty,
                                              scale: textScale)
                    Group {
                        if isLandscape {
                            landscapeLayout(metrics)
                        } else {
                            portraitLayout(metrics)
                        }
                    }
                    .frame(width: geo.size.width, height: available,
                           alignment: .top)
                    .animation(.easeOut(duration: keyboard.duration),
                               value: keyboard.overlap)
                    .onChange(of: keyboard.overlap) { _, overlap in
                        keyboardLog.debug("""
                            overlap=\(overlap, privacy: .public)                             geo=\(geo.size.height, privacy: .public)                             available=\(available, privacy: .public)                             orb=\(metrics.orb, privacy: .public)                             transcript=\(metrics.transcript, privacy: .public)                             status=\(metrics.status, privacy: .public)                             content=\(metrics.contentHeight, privacy: .public)
                            """)
                        // The one condition that means the composer is under
                        // the keyboard again. Loud, and persisted, because it
                        // is the whole bug.
                        if metrics.contentHeight + AskMetrics.chrome > available + 1 {
                            keyboardLog.error("""
                                Ask content \(metrics.contentHeight + AskMetrics.chrome, privacy: .public)pt                                 exceeds \(available, privacy: .public)pt - the composer is covered
                                """)
                        }
                    }
                }
                .ignoresSafeArea(.keyboard, edges: .bottom)
            }
            .navigationTitle("Ask")
            .navigationBarTitleDisplayMode(.inline)
            // AN EMPTY NAVIGATION BAR, ON PURPOSE.
            //
            // It carried two glyphs and neither survived. The grid opened a
            // dropdown of every destination, duplicating the radial launcher
            // in a permanent control - and the launcher is THE launcher, held
            // anywhere on the glass, which is the whole reason the tab bar
            // went. The gear opened Settings, a page touched about twice a
            // year, from the app's front screen; it is a tile now, out at the
            // end of first reach with Morning.
            //
            // What the grid was actually load-bearing for was accessibility:
            // press-and-sweep is unusable by VoiceOver and Switch Control, so
            // dropping it would have locked those users into whatever screen
            // the app opened on. That floor moved to the orb rather than
            // disappearing - see `orbControl`.
            //
            // NO keyboard accessory bar either. "Ask" duplicated the send
            // arrow sitting inches away in the composer, and "Done" is a
            // control nobody needs on a phone - tapping away from a field is
            // what people already do. Both are replaced by
            // `.dismissesKeyboard(when:)` on everything above the composer;
            // see DismissesKeyboard.swift for why the old under-the-content
            // catcher never fired.
        }
        .task(id: state.serviceGeneration) {
            model.update(service: state.service)
            morning.update(service: state.service)
            await morning.refresh()
        }
        // The window opens and closes while the app is closed, so coming back
        // is exactly when the answer may have changed.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await morning.refresh() } }
        }
        .onChange(of: composerFocused) { _, focused in
            withAnimation(.easeOut(duration: 0.18)) { composerActive = focused }
        }
        // "Pull up my Haas MBA letter" now opens it HERE too, not only on the
        // wall display - the answer card keeps a way back in, so dismissing
        // this costs nothing.
        .sheet(item: $model.presentedDocument) { doc in
            DocumentPopup(document: doc, service: state.service)
        }
    }

    // MARK: - Layouts

    /// The original single-column screen, sized by `AskMetrics`.
    ///
    /// Every block takes the height it is given rather than one it declares,
    /// which is the whole fix: the column can no longer be taller than the
    /// space it has, so nothing can be pushed under the keyboard.
    private func portraitLayout(_ metrics: AskMetrics) -> some View {
        VStack(spacing: Theme.Space.l) {
            VStack(spacing: Theme.Space.l) {
                FreshnessBanner(state: state.freshness)
                    .padding(.horizontal, Theme.Space.screen)

                MorningConfirmBanner(model: morning)
                    .padding(.horizontal, Theme.Space.screen)

                Spacer(minLength: 0)

                if metrics.showsOrb {
                    orbControl(side: metrics.orb)
                }

                statusLine(height: metrics.status,
                           showsMessage: metrics.showsStatusMessage)

                Spacer(minLength: 0)
            }
            .dismissesKeyboard(when: composerFocused) { composerFocused = false }

            typeField
                .padding(.bottom, Theme.Space.xs)

            if metrics.showsTranscript {
                transcript(maxHeight: metrics.transcript)
                    .dismissesKeyboard(when: composerFocused) { composerFocused = false }
            }
        }
        .padding(.top, Theme.Space.s)
        .animation(Theme.quick, value: composerFocused)
    }

    /// Landscape: orb and status on the left, conversation on the right. The
    /// portrait stack's fixed heights (260 orb + 54 status + composer + 260
    /// transcript) do not fit a phone on its side; two columns do.
    private func landscapeLayout(_ metrics: AskMetrics) -> some View {
        HStack(spacing: 0) {
            VStack(spacing: Theme.Space.s) {
                Spacer(minLength: 0)
                // Sized, not scaled. `scaleEffect` does not change the space a
                // view takes, so a 260pt orb drawn at 0.72 still LAID OUT as
                // 260 and pushed the column past the screen on its side. The
                // orb takes a side now and renders to it.
                if metrics.showsOrb {
                    orbControl(side: metrics.orb)
                }
                statusLine(height: metrics.status,
                           showsMessage: metrics.showsStatusMessage)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: 250)
            .padding(.leading, Theme.Space.m)
            .dismissesKeyboard(when: composerFocused) { composerFocused = false }

            VStack(spacing: Theme.Space.s) {
                FreshnessBanner(state: state.freshness)
                MorningConfirmBanner(model: morning)
                transcript(maxHeight: .infinity)
                    .dismissesKeyboard(when: composerFocused) { composerFocused = false }
                Spacer(minLength: 0)
                // Pinned to the bottom of a column that is itself framed to
                // the height the keyboard left, so it is above the keyboard by
                // construction.
                typeField
                    .padding(.bottom, Theme.Space.xs)
            }
            .padding(.top, Theme.Space.s)
        }
    }

    // MARK: - Pieces

    /// The orb IS the talk control. Holding the thing that reacts to your
    /// voice is a smaller idea to hold in your head than a separate button
    /// that operates it - the instrument and the control are one object.
    ///
    /// It used to be the app's accessible launcher as well. That job moved to
    /// `DestinationActions` in RootView, because this view is conditional -
    /// `metrics.showsOrb` - and a navigation floor cannot be.
    private func orbControl(side: CGFloat) -> some View {
        OrbView(phase: model.phase, side: side) { [weak model] in
            model?.orbLevel ?? 0
        }
        .contentShape(Circle())
        // Holding the orb is how you ask a question. Without this the radial
        // launcher would open a third of a second into every spoken question
        // and cancel the recording underneath it.
        .pressMenuExclusion()
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                // `onChanged` fires on EVERY movement of the finger, not once
                // per press, and `beginListening` is async - permission check,
                // audio session, engine start - so `phase` does not reach
                // `.listening` for tens of milliseconds. Every touch report in
                // that window passed both guards and started another
                // concurrent open of the microphone.
                //
                // `isStartingListen` is the missing half: the guard has to
                // cover the work in flight, not just the state it eventually
                // produces. Cleared by the same release that stops the turn,
                // so a gesture that ends before the mic opens cannot leave it
                // latched.
                .onChanged { _ in
                    guard !isStartingListen, model.canRecord,
                          model.phase != .listening else { return }
                    isStartingListen = true
                    Task {
                        await model.beginListening()
                        isStartingListen = false
                    }
                }
                .onEnded { _ in
                    isStartingListen = false
                    model.endListening()
                }
        )
        .accessibilityElement()
        .accessibilityLabel("Ask a question")
        .accessibilityHint("Double tap to start listening, then double tap again to send.")
        .accessibilityAction {
            // VoiceOver cannot hold; toggle instead.
            if model.phase == .listening {
                model.endListening()
            } else {
                Task { await model.beginListening() }
            }
        }
        // NO destination actions here any more. They were on the orb, and the
        // orb is the first thing `AskMetrics` deletes when the screen runs out
        // of height - so on a small phone at an accessibility text size with
        // the keyboard up, the app's only accessible navigation disappeared
        // along with it. They live in `DestinationActions` in RootView now,
        // which nothing sizes and nothing can take away. See there.
    }

    /// The phase, and what is being heard under it.
    ///
    /// `showsMessage` is off when the screen is too short for both - see
    /// AskMetrics. What survives is the phase, because "Listening" is the part
    /// that answers "is it hearing me"; the line under it is a hint, and a
    /// hint is what a short screen can afford to lose. The one exception is a
    /// failure, which is never dropped: an error nobody is shown is worse than
    /// a cramped screen.
    private func statusLine(height: CGFloat, showsMessage: Bool) -> some View {
        VStack(spacing: Theme.Space.xs) {
            Text(model.phase.label)
                .font(.ataruTitle())
                .foregroundStyle(Theme.textPrimary)
                .contentTransition(.opacity)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            if showsMessage || isFailed {
                Group {
                    if model.phase == .listening, !model.dictation.transcript.isEmpty {
                        Text(model.dictation.transcript)
                            .foregroundStyle(Theme.textSecondary)
                    } else if case .failed(let message) = model.phase {
                        Text(message)
                            .foregroundStyle(Theme.amber)
                    } else {
                        Text(hint)
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                .font(.ataruCaption())
                .multilineTextAlignment(.center)
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.horizontal, Theme.Space.l)
            }
        }
        .frame(height: height, alignment: .top)
        .clipped()
        .animation(Theme.quick, value: model.phase)
    }

    private var isFailed: Bool {
        if case .failed = model.phase { return true }
        return false
    }

    /// Demo mode says so; live mode says nothing.
    ///
    /// The live copy used to list what could be asked ("your schedule, mail,
    /// records, or anything else"). That is onboarding text on a screen its
    /// only user has seen thousands of times - and it sits directly under the
    /// orb, which is exactly where the radial launcher fans out, so it was
    /// permanent clutter showing through the tiles.
    private var hint: String {
        state.isDemo
            ? "Demo mode answers from sample files."
            : ""
    }

    /// Typing lives inline, not behind a sheet. The orb above is the voice
    /// path; this is the whole text path - one screen, both doors open.
    private var typeField: some View {
        VStack(spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.s) {
                TextField("Type instead", text: $model.typedQuestion, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.ataruBody())
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1...4)
                    .focused($composerFocused)
                    // NOT .send: this field has a vertical axis, so the
                    // software Return inserts a newline and never fires
                    // onSubmit - a key labelled "send" that types a blank
                    // line instead. (A hardware Return does submit, which is
                    // why it survives testing with a Mac keyboard attached.)
                    // onSubmit stays for that hardware path; the keyboard bar
                    // carries the real send affordance.
                    .submitLabel(.return)
                    .onSubmit { submit() }
                    .accessibilityIdentifier("question-field")

                Button {
                    submit()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(canSubmitTyped ? Theme.cyan : Theme.textTertiary)
                }
                .disabled(!canSubmitTyped)
                .accessibilityLabel("Ask")
                .accessibilityIdentifier("submit-question")
            }
            .padding(.horizontal, Theme.Space.m)
            .frame(minHeight: (Theme.minHitTarget + 8) * min(max(textScale, 1), 2.4))
            .background {
                RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                    .fill(Theme.surface)
            }
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                    .strokeBorder(Theme.border, lineWidth: 1)
            }
            // The capsule focuses the field, not just the 19pt strip of text
            // inside it.
            //
            // A vertical-axis TextField lays itself out to the height of its
            // *content* — one line — so the element that takes taps was a
            // sliver in the middle of a 52pt control, and most of what looks
            // like the text box did nothing. That is why the keyboard would not
            // come up: the taps were landing on padding. `contentShape` makes
            // the whole capsule a target and the tap hands focus to the field.
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.large,
                                           style: .continuous))
            .onTapGesture { composerFocused = true }
            // A hold on a text field is how iOS offers the magnifier and
            // "Paste". The launcher must not take that away, even before the
            // field has focus.
            .pressMenuExclusion()

            if model.phase == .speaking {
                Button("Stop") { model.stopSpeaking() }
                    .font(.ataruCaption())
                    .foregroundStyle(Theme.amber)
            }
        }
        .padding(.horizontal, Theme.Space.screen)
    }

    /// Submitting always puts the keyboard away: the answer is about to be
    /// read (and possibly spoken), which is a reading posture, not a typing
    /// one. Focus was the missing half of the old submit path.
    private func submit() {
        model.submitTypedQuestion()
        composerFocused = false
    }

    private var canSubmitTyped: Bool {
        !model.typedQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @ViewBuilder
    private func transcript(maxHeight: CGFloat) -> some View {
        if model.exchanges.isEmpty {
            Color.clear.frame(height: 120)
        } else {
            ScrollView {
                LazyVStack(spacing: Theme.Space.s) {
                    ForEach(model.exchanges) { exchange in
                        ExchangeCard(exchange: exchange,
                                     replay: { model.replay(exchange) },
                                     reopen: exchange.document.map { doc in
                                         { model.presentedDocument = doc }
                                     })
                    }
                }
                .padding(.horizontal, Theme.Space.screen)
                .padding(.bottom, Theme.Space.m)
            }
            .scrollDismissesKeyboard(.interactively)
            .frame(maxHeight: maxHeight)
        }
    }
}

/// One question and its answer.
private struct ExchangeCard: View {
    let exchange: VoiceExchange
    let replay: () -> Void
    /// Re-opens the document this answer pulled up. Dismissing the popup has
    /// to be cheap, which means getting back in has to be cheap too.
    var reopen: (() -> Void)?

    var body: some View {
        ATCard {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(exchange.question)
                    .font(.ataruCaption())
                    .foregroundStyle(Theme.textTertiary)
                Text(exchange.answer)
                    .font(.ataruBody())
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: Theme.Space.s) {
                    if let document = exchange.document, let reopen {
                        Button(action: reopen) {
                            Label(document.title, systemImage: "doc.richtext")
                                .font(.ataruCaption())
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.cyan)
                        .accessibilityLabel("Open \(document.title)")
                    } else if let source = exchange.source {
                        // The filename only: the full vault path is a
                        // directory tree the user does not need read back.
                        Label(URL(fileURLWithPath: source).lastPathComponent,
                              systemImage: "doc.text")
                            .font(.ataruCaption())
                            .foregroundStyle(Theme.cyanSubdued)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Button(action: replay) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 12))
                            .hitTarget()
                    }
                    .foregroundStyle(Theme.textSecondary)
                    .accessibilityLabel("Play this answer again")
                }
            }
            .padding(Theme.Space.m)
        }
    }
}

#Preview {
    VoiceView().environmentObject(AppState())
}
