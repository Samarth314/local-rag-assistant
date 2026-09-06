import SwiftUI

/// "I'm up" - saying so with a thumb instead of a voice.
///
/// ## Why this exists
///
/// The morning call rings every fifteen minutes until he picks up AND speaks.
/// Answering alone has never been enough on purpose: on 2026-08-16 he answered
/// - in his sleep, as far as anyone can tell - said nothing, and remembers none
/// of it. The ladder re-armed and spent all six attempts, which is the ladder
/// being right. A pocket answer must not be able to silence it.
///
/// What was missing was a deliberate way to end it without talking. This is
/// that: one button, and the server records it through exactly the same
/// machinery a spoken confirmation goes through, so there is one definition of
/// "confirmed" and the redial ladder cannot learn about this path separately.
///
/// SPEECH STILL CONFIRMS. This is an additional path, never a replacement.
///
/// ## What the model owns
///
/// Whether to offer it at all (the server decides, see `MorningCallState`),
/// the in-flight state of one tap, and the brief acknowledgement afterwards.
///
/// ## ONE INSTANCE, OWNED BY AppState
///
/// It was written to be shared and then was not: `VoiceView` and
/// `CallSessionView` each held their own `@StateObject`, so there were two
/// copies of "has he confirmed" and neither could see the other. Three things
/// followed, all of them reported:
///
/// 1. Tapping "I'm up" on the call screen did not retract the Ask page's
///    banner, which went on offering to confirm a call already confirmed.
/// 2. The call screen never called `refresh()` at all - it drew its button
///    whenever the call was a morning call, ignoring `isOffered` entirely -
///    so the button appeared for a morning call he had already answered by
///    speaking.
/// 3. That same unguarded button stayed in the header after the call ended.
///
/// The model now lives on `AppState` and every surface asks it the same
/// question, `isPresented`. A tap anywhere settles it for all of them in the
/// same run loop, because there is only one of them.
@MainActor
final class MorningConfirmModel: ObservableObject {

    enum Phase: Equatable {
        case idle
        case sending
        /// Recorded. The ladder stands down.
        case confirmed
        /// The server had no call in flight - honest, and NOT dressed up as
        /// success: telling him the calls will stop when they will not is the
        /// one outcome worse than no button.
        case nothingToConfirm
        case failed
    }

    @Published private(set) var phase: Phase = .idle
    /// Whether the server says there is a call this thumb can end.
    ///
    /// `can_confirm && !confirmed`, and nothing else - never inferred from a
    /// clock on this device, which knows neither the wake schedule, nor
    /// whether the call actually rang, nor whether he already spoke. It used
    /// to be `in_call_window`, which is a wider claim: the window is open for
    /// the whole ladder, including after a confirmation has landed.
    @Published private(set) var isOffered = false

    /// Set the instant a tap lands, before the POST has answered.
    ///
    /// THIS IS WHAT MAKES EVERY SURFACE RETRACT TOGETHER. Waiting for the
    /// round trip would leave the banner he did not tap sitting there for as
    /// long as a 7am tailnet takes to answer, which is exactly when it is
    /// slowest. Reverted on failure - and only on failure, which is the one
    /// outcome where the calls really will keep coming.
    @Published private(set) var isSettledLocally = false

    private var service: ATARUService?

    func update(service: ATARUService) {
        self.service = service
    }

    /// The one question every surface asks.
    ///
    /// A button or banner exists when the server says there is something to
    /// confirm and nothing has settled it yet, or when there is something to
    /// SAY about a tap that just happened. Nothing else may draw one - in
    /// particular, "this is a morning call" is not a reason.
    /// `.sending` is included on purpose. The offer is already withdrawn by
    /// then - `isActionable` is false and both surfaces disable the control -
    /// so nothing invites a second tap; keeping the ROW means the tap does not
    /// vanish and then reappear a round trip later as an acknowledgement,
    /// which reads as a glitch rather than as progress.
    var isPresented: Bool {
        (isOffered && !isSettledLocally) || phase == .sending
            || acknowledgement != nil || failureMessage != nil
    }

    /// Ask the server whether the button is worth showing.
    ///
    /// Silent on failure: a banner that appears because a poll failed is worse
    /// than one that never appears, and there is nothing here the user can act
    /// on.
    func refresh() async {
        guard let service else { return }
        let state = (try? await service.morningCallState()) ?? .inactive
        withAnimation(Theme.spring) {
            isOffered = state.canConfirm && !state.confirmed
            if state.confirmed {
                // A confirmation the server already knows about - he spoke, he
                // tapped on the other surface, he tapped yesterday and the
                // window is still open - retires EVERYTHING, the
                // acknowledgement included.
                //
                // The acknowledgement is feedback for a tap that just
                // happened, not a fact about the day. Reconstructing it from a
                // poll is what left "Good morning. No more calls." sitting in
                // the header above the orb long after the call was over, which
                // is the bug this whole file was rewritten for. Server truth
                // means nothing to show, not something nice to show.
                isSettledLocally = true
                if phase != .sending { phase = .idle }
            } else if !state.inCallWindow {
                // The window closed with nothing outstanding. Back to nothing
                // on screen at all, which is the resting state of this whole
                // feature.
                isSettledLocally = false
                if phase != .sending { phase = .idle }
            }
        }
    }

    func confirm() async {
        guard let service, phase != .sending else { return }
        // Optimistic, and deliberately before the await. Every surface reads
        // `isPresented`, so all of them stop offering in this run loop.
        withAnimation(Theme.spring) {
            isSettledLocally = true
            phase = .sending
        }
        Haptics.fire(.tap)
        do {
            let recorded = try await service.confirmMorningCall()
            withAnimation(Theme.spring) {
                phase = recorded ? .confirmed : .nothingToConfirm
                if recorded { isOffered = false }
            }
            Haptics.fire(recorded ? .success : .warning)
        } catch {
            // The one path back. Nothing was recorded, the ladder is still
            // ringing, so the offer has to come back everywhere it went away.
            withAnimation(Theme.spring) {
                phase = .failed
                isSettledLocally = false
            }
            Haptics.fire(.failure)
        }
    }

    /// What the surface says after a tap, when the tap SETTLED something.
    ///
    /// A failure settles nothing, so it is deliberately not here - see
    /// `failureMessage`. It used to be, and that was the dead end: the
    /// acknowledgement replaced the button, so the one outcome that needs
    /// another tap was the one outcome with nothing left to tap. At 7am
    /// against a tailnet that is not up yet, it is also the likeliest outcome.
    var acknowledgement: String? {
        switch phase {
        case .idle, .sending, .failed: return nil
        case .confirmed:               return "Good morning. No more calls."
        case .nothingToConfirm:        return "No call to confirm right now."
        }
    }

    /// Shown ALONGSIDE the button, never instead of it.
    var failureMessage: String? {
        phase == .failed ? "Couldn't reach ATARU." : nil
    }

    /// What the button says. A retry has to look like a retry, or a half-awake
    /// thumb reads the unchanged "I'm up" as a button that did nothing.
    var actionTitle: String { phase == .failed ? "Try again" : "I'm up" }

    var actionIcon: String {
        phase == .failed ? "arrow.clockwise" : "sun.horizon.fill"
    }

    /// Whether a tap is still worth offering. Re-attemptable indefinitely on
    /// failure: the ladder is still ringing, so there is still something to
    /// confirm, however many times the network has refused.
    ///
    /// Not while one is in flight. That used to be enforced only by each
    /// surface's own `.disabled(phase == .sending)`, which was true of both
    /// buttons independently and of neither of them together - two models, two
    /// phases. One model makes it one answer.
    var isActionable: Bool { acknowledgement == nil && phase != .sending }

    var isDone: Bool { phase == .confirmed }
}

// MARK: - The call-screen button

/// The prominent one, for a phone held at arm's length at seven in the morning.
///
/// Deliberately large and deliberately alone in its row: this is the one
/// control on that screen that has to be findable by someone who is not
/// properly awake, and a half-asleep thumb does not aim.
///
/// SELF-GATING. The call screen used to decide for itself whether to draw
/// this - `if call.isMorningCall` and nothing else - which is a different
/// question from the one the server answers, and is why the button outlived
/// the thing it confirms. The gate lives here now, so every caller gets the
/// same rule and none of them can get it wrong.
struct MorningConfirmButton: View {
    @ObservedObject var model: MorningConfirmModel

    var body: some View {
        Group {
            if model.isPresented { content }
        }
        .animation(Theme.spring, value: model.isPresented)
    }

    private var content: some View {
        VStack(spacing: Theme.Space.xs) {
            // Above the button, not in place of it. The tap is still available
            // and still means the same thing.
            if let failure = model.failureMessage {
                Label(failure, systemImage: "exclamationmark.circle")
                    .font(.ataruCaption())
                    .foregroundStyle(Theme.amber)
                    .transition(.opacity)
            }

            if let acknowledgement = model.acknowledgement {
                Label(acknowledgement, systemImage: model.isDone
                      ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .font(.ataruCaption())
                    .foregroundStyle(model.isDone ? Theme.green : Theme.amber)
                    .transition(.opacity)
            } else {
                Button {
                    Task { await model.confirm() }
                } label: {
                    HStack(spacing: Theme.Space.xs) {
                        Image(systemName: model.actionIcon)
                            // The icon swap IS the state: a retry that looks
                            // identical to the first attempt reads as a button
                            // that did nothing.
                            .contentTransition(.symbolEffect(.replace))
                        Text(model.actionTitle)
                    }
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.onAccent)
                    .frame(maxWidth: .infinity)
                    // Well past the 44pt floor: the target should be
                    // unmissable, not merely legal.
                    .frame(height: 54)
                    .background(Theme.cyan, in: Capsule())
                    .opacity(model.phase == .sending ? 0.6 : 1)
                }
                .buttonStyle(.plain)
                .disabled(model.phase == .sending)
                .accessibilityLabel(model.actionTitle)
                .accessibilityHint("Tells ATARU you are awake so it stops calling back.")
                .transition(.opacity)
            }
        }
        .animation(Theme.spring, value: model.phase)
    }
}

// MARK: - The Ask-page banner

/// The one he will actually find.
///
/// The call screen's button only exists while the call does, and a call he
/// half-answered is a call he may well have already hung up. The app is the
/// other place a half-awake hand goes, so the offer is repeated there - subtle,
/// one tap, and gone the moment the server says the window has closed.
struct MorningConfirmBanner: View {
    @ObservedObject var model: MorningConfirmModel

    var body: some View {
        Group {
            // A failed attempt keeps the banner up even if the offer poll has
            // gone quiet: the ladder is still ringing and the tap still needs
            // somewhere to live. That is folded into `isPresented`, which is
            // now the one rule - the call screen asks the same question, so a
            // tap there takes this away in the same run loop.
            if model.isPresented {
                HStack(spacing: Theme.Space.s) {
                    Image(systemName: model.isDone ? "checkmark.circle.fill"
                          : (model.failureMessage != nil ? "exclamationmark.circle"
                                                         : "sun.horizon.fill"))
                        .font(.system(size: 13, weight: .semibold))
                    Text(model.acknowledgement ?? model.failureMessage
                         ?? "ATARU is calling this morning.")
                        .font(.ataruCaption())
                    Spacer(minLength: Theme.Space.xs)
                    if model.isActionable {
                        Button {
                            Task { await model.confirm() }
                        } label: {
                            Text(model.actionTitle)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Theme.onAccent)
                                .padding(.horizontal, Theme.Space.s)
                                .frame(height: 32)
                                .background(Theme.cyan, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(model.phase == .sending)
                        .accessibilityLabel(model.actionTitle)
                        .accessibilityHint("Tells ATARU you are awake so it stops calling back.")
                    }
                }
                .foregroundStyle(model.isDone ? Theme.green
                                 : (model.failureMessage != nil ? Theme.amber
                                                                : Theme.textSecondary))
                .padding(.horizontal, Theme.Space.s)
                .padding(.vertical, Theme.Space.xs)
                .background {
                    RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                        .fill((model.isDone ? Theme.green : Theme.cyan).opacity(0.10))
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(Theme.spring, value: model.isPresented)
        .animation(Theme.spring, value: model.phase)
    }
}
