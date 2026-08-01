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

                    OrbView(phase: model.phase, level: model.dictation.level)

                    statusLine

                    Spacer(minLength: 0)

                    talkButton
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
            .sheet(isPresented: $model.isShowingTypeField) { typeSheet }
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
            : "Ask about anything in your indexed documents."
    }

    private var talkButton: some View {
        VStack(spacing: Theme.Space.s) {
            Button {
                // The press-and-hold gesture below does the work; this action
                // fires only for VoiceOver's activate, where "hold" is not a
                // gesture the user can perform.
                if model.phase == .listening {
                    model.endListening()
                } else {
                    Task { await model.beginListening() }
                }
            } label: {
                Text(model.phase == .listening ? "Release to ask" : "Hold to speak")
                    .font(.ataruBody())
                    .foregroundStyle(model.canRecord || model.phase == .listening
                                     ? Theme.textPrimary : Theme.textTertiary)
                    .frame(maxWidth: .infinity, minHeight: Theme.minHitTarget + 12)
                    .background {
                        RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                            .fill(model.phase == .listening
                                  ? Theme.cyan.opacity(0.16) : Theme.surface)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                            .strokeBorder(model.phase == .listening
                                          ? Theme.cyan.opacity(0.6) : Theme.border, lineWidth: 1)
                    }
            }
            .disabled(model.phase.isBusy)
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard model.canRecord, model.phase != .listening else { return }
                        Task { await model.beginListening() }
                    }
                    .onEnded { _ in model.endListening() }
            )
            .accessibilityLabel("Ask a question")
            .accessibilityHint("Double tap to start listening, then double tap again to send.")

            HStack(spacing: Theme.Space.m) {
                Button("Type instead") { model.isShowingTypeField = true }
                    .font(.ataruCaption())
                    .foregroundStyle(Theme.textSecondary)

                if model.phase == .speaking {
                    Button("Stop") { model.stopSpeaking() }
                        .font(.ataruCaption())
                        .foregroundStyle(Theme.amber)
                }
            }
        }
        .padding(.horizontal, Theme.Space.screen)
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

    private var typeSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                Text("Ask in writing")
                    .font(.ataruTitle())
                    .foregroundStyle(Theme.textPrimary)
                TextField("What would you like to know?", text: $model.typedQuestion, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.ataruBody())
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2...6)
                    .padding(Theme.Space.s)
                    .background {
                        RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                            .fill(Theme.surface)
                    }
                    .submitLabel(.send)
                    .onSubmit { model.submitTypedQuestion() }
                    .accessibilityIdentifier("question-field")
                Spacer()
            }
            .padding(Theme.Space.screen)
            .frame(maxWidth: .infinity, alignment: .leading)
            .ataruBackdrop()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { model.isShowingTypeField = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Ask") { model.submitTypedQuestion() }
                        .disabled(model.typedQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        // "Ask" is also the tab and the navigation title, so
                        // this button needs an unambiguous handle for tests.
                        .accessibilityIdentifier("submit-question")
                }
            }
        }
        .presentationDetents([.medium])
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
