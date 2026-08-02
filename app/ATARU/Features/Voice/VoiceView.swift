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

                // Exists only while the keyboard is up, so it can never
                // interfere with the tap that ACQUIRES focus - a plain
                // always-on backdrop tap handler turned out to race the
                // field's own tap and the keyboard never appeared.
                if composerFocused {
                    Color.clear
                        .contentShape(Rectangle())
                        .ignoresSafeArea()
                        .onTapGesture { composerFocused = false }
                }

                GeometryReader { geo in
                    Group {
                        if geo.size.width > geo.size.height {
                            landscapeLayout
                        } else {
                            portraitLayout
                        }
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                }
            }
            .navigationTitle("Ask")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
                // The vertical-axis field turns Return into newline, so the
                // keyboard needs its own explicit way out.
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { composerFocused = false }
                        .font(.ataruLabel())
                }
            }
        }
        .task(id: ObjectIdentifier(state.service)) {
            model.update(service: state.service)
        }
        .onChange(of: composerFocused) { _, focused in
            withAnimation(.easeOut(duration: 0.18)) { composerActive = focused }
        }
    }

    // MARK: - Layouts

    /// The original single-column screen.
    private var portraitLayout: some View {
        VStack(spacing: Theme.Space.l) {
            FreshnessBanner(state: state.freshness)
                .padding(.horizontal, Theme.Space.screen)

            Spacer(minLength: 0)

            orbControl

            statusLine

            Spacer(minLength: 0)

            typeField
                .padding(.bottom, Theme.Space.xs)

            transcript(maxHeight: 260)
        }
        .padding(.top, Theme.Space.s)
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

            VStack(spacing: Theme.Space.s) {
                FreshnessBanner(state: state.freshness)
                transcript(maxHeight: .infinity)
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

    private var hint: String {
        state.configuration.mode == .demo
            ? "Demo mode answers from sample files."
            // Live ATARU is not a document search box. The same question can
            // reach mail, the calendar, records or the live web, so the hint
            // must not promise only files.
            : "Ask about your schedule, mail, records, or anything else."
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
                    .submitLabel(.send)
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
                        ExchangeCard(exchange: exchange) { model.replay(exchange) }
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
                    if let source = exchange.source {
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
