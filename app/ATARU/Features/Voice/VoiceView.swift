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
    /// Measured, not assumed - see KeyboardInset for why the automatic
    /// avoidance cannot reach this screen.
    @StateObject private var keyboard = KeyboardInset()
    /// Reported upward so RootView can hide the radial launcher while the
    /// user is typing - the dial used to float on top of the composer.
    @Binding private var composerActive: Bool

    init(composerActive: Binding<Bool> = .constant(false)) {
        // Replaced in `.task` once the environment's service is known; a
        // StateObject cannot read the environment during init.
        _model = StateObject(wrappedValue: VoiceViewModel(service: DemoATARUService()))
        _composerActive = composerActive
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Ataru.backdrop.ignoresSafeArea()

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
                    Group {
                        if geo.size.width > geo.size.height {
                            landscapeLayout
                        } else {
                            portraitLayout
                        }
                    }
                    .frame(width: geo.size.width,
                           height: max(160, geo.size.height - keyboard.overlap),
                           alignment: .top)
                    .animation(.easeOut(duration: keyboard.duration),
                               value: keyboard.overlap)
                }
                .ignoresSafeArea(.keyboard, edges: .bottom)
            }
            .navigationTitle("Ask")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // The only route between screens that does not require
                // press-and-sweep. Not decoration — see TileDestinationsMenu.
                ToolbarItem(placement: .topBarLeading) { TileDestinationsMenu() }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
                // NO keyboard accessory bar. "Ask" duplicated the send arrow
                // sitting inches away in the composer, and "Done" is a control
                // nobody needs on a phone - tapping away from a field is what
                // people already do. Both are replaced by
                // `.dismissesKeyboard(when:)` on everything above the composer;
                // see DismissesKeyboard.swift for why the old under-the-content
                // catcher never fired.
            }
        }
        .task(id: ObjectIdentifier(state.service)) {
            model.update(service: state.service)
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

    /// The original single-column screen.
    private var portraitLayout: some View {
        VStack(spacing: Theme.Space.l) {
            VStack(spacing: Theme.Space.l) {
                FreshnessBanner(state: state.freshness)
                    .padding(.horizontal, Theme.Space.screen)

                Spacer(minLength: 0)

                orbControl

                statusLine

                Spacer(minLength: 0)
            }
            .dismissesKeyboard(when: composerFocused) { composerFocused = false }

            typeField
                .padding(.bottom, Theme.Space.xs)

            // With the keyboard up there is no room for this AND the composer.
            // The fixed costs above - a 260pt orb, a 54pt status line, a 52pt
            // composer - already overflow the screen before any keyboard
            // exists, and a 120pt BLANK placeholder sitting under the composer
            // pushed the field itself below the fold. Drop the placeholder
            // while typing and cap a real transcript, so the field the
            // keyboard is attached to is actually visible.
            if !(composerFocused && model.exchanges.isEmpty) {
                transcript(maxHeight: composerFocused ? 140 : 260)
                    .dismissesKeyboard(when: composerFocused) { composerFocused = false }
            }
        }
        .padding(.top, Theme.Space.s)
        .animation(.easeOut(duration: 0.18), value: composerFocused)
    }

    /// Landscape: orb and status on the left, conversation on the right. The
    /// portrait stack's fixed heights (260 orb + 54 status + composer + 260
    /// transcript) do not fit a phone on its side; two columns do.
    private var landscapeLayout: some View {
        HStack(spacing: 0) {
            VStack(spacing: Theme.Space.s) {
                Spacer(minLength: 0)
                orbControl
                    .scaleEffect(0.72)
                    .frame(width: 190, height: 190)
                statusLine
                Spacer(minLength: 0)
            }
            .frame(maxWidth: 250)
            .padding(.leading, Theme.Space.m)
            .dismissesKeyboard(when: composerFocused) { composerFocused = false }

            VStack(spacing: Theme.Space.s) {
                FreshnessBanner(state: state.freshness)
                transcript(maxHeight: .infinity)
                    .dismissesKeyboard(when: composerFocused) { composerFocused = false }
                Spacer(minLength: 0)
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
    private var orbControl: some View {
        OrbView(phase: model.phase) { [weak model] in
            model?.orbLevel ?? 0
        }
        .contentShape(Circle())
        // Holding the orb is how you ask a question. Without this the radial
        // launcher would open a third of a second into every spoken question
        // and cancel the recording underneath it.
        .pressMenuExclusion()
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard model.canRecord, model.phase != .listening else { return }
                    Task { await model.beginListening() }
                }
                .onEnded { _ in model.endListening() }
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
    }

    private var statusLine: some View {
        VStack(spacing: Theme.Space.xs) {
            Text(model.phase.label)
                .font(.ataruTitle())
                .foregroundStyle(Theme.textPrimary)
                .contentTransition(.opacity)

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
            .frame(minHeight: 54, alignment: .top)
            .padding(.horizontal, Theme.Space.l)
        }
        .animation(.easeInOut(duration: 0.2), value: model.phase)
    }

    /// Demo mode says so; live mode says nothing.
    ///
    /// The live copy used to list what could be asked ("your schedule, mail,
    /// records, or anything else"). That is onboarding text on a screen its
    /// only user has seen thousands of times - and it sits directly under the
    /// orb, which is exactly where the radial launcher fans out, so it was
    /// permanent clutter showing through the tiles.
    private var hint: String {
        state.configuration.mode == .demo
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
            .frame(minHeight: Theme.minHitTarget + 8)
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
