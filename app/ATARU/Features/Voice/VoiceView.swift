import SwiftUI

/// Ask ATARU out loud.
///
/// Hold to speak, release to send. Holding rather than tapping is deliberate:
/// it makes the end of the question unambiguous, so nothing has to guess when
/// the user stopped talking, and releasing early is a natural cancel.
struct VoiceView: View {
    @EnvironmentObject private var state: AppState
    @StateObject private var model: VoiceViewModel

    init() {
        // Replaced in `.task` once the environment's service is known; a
        // StateObject cannot read the environment during init.
        _model = StateObject(wrappedValue: VoiceViewModel(service: DemoATARUService()))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Ataru.backdrop.ignoresSafeArea()

                VStack(spacing: Theme.Space.l) {
                    FreshnessBanner(state: state.freshness)
                        .padding(.horizontal, Theme.Space.screen)

                    Spacer(minLength: 0)

                    // The orb IS the talk control. Holding the thing that
                    // reacts to your voice is a smaller idea to hold in your
                    // head than a separate button that operates it — the
                    // instrument and the control are one object.
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

                    statusLine

                    Spacer(minLength: 0)

                    typeField
                        .padding(.bottom, Theme.Space.xs)

                    transcript
                }
                .padding(.top, Theme.Space.s)
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
            }
        }
        .task(id: ObjectIdentifier(state.service)) {
            model.update(service: state.service)
        }
    }

    // MARK: - Pieces

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
    /// path; this is the whole text path — one screen, both doors open.
    private var typeField: some View {
        VStack(spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.s) {
                TextField("Type instead", text: $model.typedQuestion, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.ataruBody())
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1...4)
                    .submitLabel(.send)
                    .onSubmit { model.submitTypedQuestion() }
                    .accessibilityIdentifier("question-field")

                Button {
                    model.submitTypedQuestion()
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

    private var canSubmitTyped: Bool {
        !model.typedQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @ViewBuilder
    private var transcript: some View {
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
            .frame(maxHeight: 260)
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
