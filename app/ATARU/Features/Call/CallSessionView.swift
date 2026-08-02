import SwiftUI

/// What the app shows while a call with ATARU is up.
///
/// ## The idea it borrows
///
/// A voice-channel UI works because it answers one question at a glance: *who
/// is talking right now*. Here that splits cleanly between the two live
/// surfaces — the orb is ATARU's side (its motion says listening, thinking,
/// or talking), and the waveform beside the controls is the caller's side,
/// moving only when the mic actually hears them. Between them they remove the
/// awkward "did it hear me, should I repeat myself" pause that otherwise
/// dominates talking to a machine, without a row of participant tiles
/// restating what the orb already shows.
///
/// ## Controls
///
/// Mute and hang up route through `CallService`, so they issue CallKit actions
/// rather than mutating state locally. Pressing mute here and pressing it on
/// the lock screen are the same action taking the same path, which is the only
/// way the two can never disagree.
struct CallSessionView: View {
    @ObservedObject var call: CallService
    @ObservedObject var session: CallSessionModel
    /// Owned by the parent, because a minimised call still exists — the state
    /// has to outlive this view being torn down.
    @Binding var isMinimized: Bool

    var body: some View {
        GeometryReader { geo in
            if geo.size.width > geo.size.height {
                landscapeBody
            } else {
                portraitBody
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            // An opaque base under the gradient. `callBackdrop` is a scrim —
            // its stops top out at 98% alpha because it is designed to sit over
            // a blur — so on its own whatever is behind shows through, and the
            // screen underneath reads straight through the call.
            ZStack {
                Ataru.Palette.bg
                Ataru.callBackdrop
            }
            .ignoresSafeArea()
        }
        // Two fingers, not one: the transcript scrolls with one, and
        // overloading that would minimise the call every time somebody read a
        // long answer.
        .twoFingerSwipe(
            up: { setMinimized(false) },
            down: { setMinimized(true) }
        )
        .accessibilityElement(children: .contain)
    }

    /// The original stacked screen.
    ///
    /// Orb, then what is being said, then who is saying it. The words sit
    /// directly under the orb because that is where the eye already is - the
    /// orb is what moves, so anything further away gets missed mid-sentence.
    ///
    /// Compacted, and not negotiable: the orb's natural size is 260pt, and at
    /// full size this screen's fixed content added up to more than the
    /// display - the transcript's flexible frame was the only thing that
    /// could give, so it silently collapsed to nothing. The words are the
    /// point of this screen; the orb yields.
    private var portraitBody: some View {
        VStack(spacing: Ataru.Space.lg) {
            minimizeBar

            header

            OrbView(phase: session.phase) { [weak session] in
                session?.orbLevel ?? 0
            }
            .scaleEffect(0.68)
            .frame(height: 180)

            transcript
                .frame(minHeight: 132, maxHeight: .infinity)

            controls
        }
        .padding(.horizontal, Ataru.Space.gutter)
        .padding(.top, Ataru.Space.md)
        .padding(.bottom, Ataru.Space.xl)
    }

    /// On its side the stack cannot fit at all (the portrait sum already
    /// exceeded a portrait screen once - see above), so landscape goes to two
    /// columns: orb + state on the left, the words and controls on the right.
    private var landscapeBody: some View {
        HStack(spacing: Ataru.Space.lg) {
            VStack(spacing: Ataru.Space.sm) {
                minimizeBar
                Spacer(minLength: 0)
                OrbView(phase: session.phase) { [weak session] in
                    session?.orbLevel ?? 0
                }
                .scaleEffect(0.55)
                .frame(width: 150, height: 150)
                header
                Spacer(minLength: 0)
            }
            .frame(maxWidth: 230)

            VStack(spacing: Ataru.Space.md) {
                transcript
                    .frame(minHeight: 80, maxHeight: .infinity)
                controls
            }
            .padding(.top, Ataru.Space.md)
        }
        .padding(.horizontal, Ataru.Space.gutter)
        .padding(.vertical, Ataru.Space.md)
    }

    private func setMinimized(_ minimized: Bool) {
        guard isMinimized != minimized else { return }
        withAnimation(.easeInOut(duration: 0.28)) { isMinimized = minimized }
        Haptics.fire(.selection)
    }

    // MARK: - Minimise

    private var minimizeBar: some View {
        HStack {
            Button { setMinimized(true) } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: Theme.minHitTarget, height: Theme.minHitTarget)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Minimise call")
            .accessibilityHint("The call keeps running. Swipe up with two fingers to bring it back.")

            Spacer()
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: Ataru.Space.sm) {
            SectionLabel(text: "Session")

            Text(stateLabel)
                .font(.system(size: 24, weight: .thin))
                .tracking(24 * 0.02)
                .foregroundStyle(Theme.textPrimary)
                .contentTransition(.opacity)
                .animation(.easeInOut(duration: Ataru.Motion.micro), value: stateLabel)

            if case .active(let connectedAt) = call.state {
                TimelineView(.periodic(from: connectedAt, by: 1)) { context in
                    Text(CallDuration.format(from: connectedAt, to: context.date))
                        .font(.ataruMono(11.5))
                        .foregroundStyle(Theme.textTertiary)
                        .monospacedDigit()
                }
                // The system call UI already announces duration; a second timer
                // read out every second is noise, not information.
                .accessibilityHidden(true)
            }
        }
    }

    private var stateLabel: String {
        switch call.state {
        case .active:
            switch session.phase {
            case .idle: return "Connected"
            case .listening: return "Listening"
            // Not necessarily a file search - the phase can't see whether the
            // answer comes from files, mail, or the model, so stay generic.
            case .thinking: return "Thinking"
            case .speaking: return "Answering"
            case .failed: return "Something went wrong"
            }
        default:
            return call.state.label
        }
    }

    // MARK: - What was said

    private var transcript: some View {
        ScrollView {
            // Centred rather than top-aligned: for most of a call there is one
            // short line here, and pinning it to the top leaves it stranded
            // above a large empty gap.
            VStack(spacing: Ataru.Space.md) {
                Spacer(minLength: 0)
                if !session.heard.isEmpty {
                    Text(session.heard)
                        .ataruStyle(.callTranscript)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .transition(.opacity)
                }

                if !session.answer.isEmpty, session.phase != .listening {
                    Text(session.answer)
                        .ataruStyle(.callAnswer)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .transition(.opacity)
                }

                if session.heard.isEmpty && session.answer.isEmpty {
                    Text(call.isMuted ? "Muted — nothing is being heard."
                                      : "Just start talking.")
                        .ataruStyle(.hint)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, Ataru.Space.sm)
            .frame(minHeight: minTranscriptHeight)
        }
        .scrollIndicators(.hidden)
        .animation(.easeInOut(duration: 0.2), value: session.answer)
        .animation(.easeInOut(duration: 0.2), value: session.heard)
    }

    /// Lets the centring Spacers above have something to divide. A ScrollView
    /// sizes to its content, so without a floor the stack collapses and the
    /// Spacers do nothing.
    private var minTranscriptHeight: CGFloat { 180 }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: Ataru.Space.md) {
            // The caller's own audio, live. Flat when the room is quiet or
            // the mic is muted, moving when the mic is actually hearing them
            // — which is the question a call screen has to answer.
            MicWaveformBar(
                dictation: session.dictation,
                isLive: session.phase == .listening && !call.isMuted,
                isMuted: call.isMuted
            )
            .frame(maxWidth: .infinity)

            CallControl(
                symbol: call.isSpeakerOn ? "speaker.wave.2.fill" : "speaker.fill",
                label: call.isSpeakerOn ? "Speaker on" : "Speaker off",
                foreground: call.isSpeakerOn ? Theme.onAccent : Theme.textPrimary,
                fill: call.isSpeakerOn ? Theme.textPrimary : nil
            ) {
                call.setSpeaker(!call.isSpeakerOn)
                Haptics.fire(.selection)
            }

            CallControl(
                symbol: call.isMuted ? "mic.slash.fill" : "mic.fill",
                label: call.isMuted ? "Unmute" : "Mute",
                foreground: call.isMuted ? Theme.onAccent : Theme.textPrimary,
                fill: call.isMuted ? Theme.textPrimary : nil
            ) {
                call.setMuted(!call.isMuted)
                Haptics.fire(.selection)
            }

            CallControl(
                symbol: "phone.down.fill",
                label: "End call",
                foreground: Theme.onAccent,
                fill: Theme.red
            ) {
                call.end()
            }
        }
    }
}

// MARK: - Pieces

/// The caller's audio as a scrolling waveform, sitting with the call controls.
///
/// Bars march right-to-left, each one the mic's peak level over one frame —
/// the Voice Memos idiom, drawn in the kit's materials. It answers "is this
/// thing hearing me" at a glance: a live mic shows movement the moment the
/// caller speaks, a muted or resting one settles to a flat line.
private struct MicWaveformBar: View {
    @ObservedObject var dictation: SpeechDictation
    /// Whether the mic is actually feeding the recogniser right now.
    let isLive: Bool
    let isMuted: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var history = LevelHistory()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { _ in
            Canvas { context, size in
                history.push(isLive ? dictation.level : 0)

                let barWidth: CGFloat = 2.5
                let gap: CGFloat = 2.5
                let count = min(history.samples.count,
                                Int((size.width - gap) / (barWidth + gap)))
                let midY = size.height / 2
                let maxRise = size.height * 0.38

                for i in 0..<count {
                    // Newest sample at the right edge, like tape moving left.
                    let sample = history.samples[history.samples.count - count + i]
                    let rise = max(1.2, CGFloat(sample) * maxRise)
                    let x = size.width - gap - barWidth
                        - CGFloat(count - 1 - i) * (barWidth + gap)
                    let bar = CGRect(x: x, y: midY - rise,
                                     width: barWidth, height: rise * 2)
                    context.fill(
                        Path(roundedRect: bar, cornerRadius: barWidth / 2),
                        with: .color(Theme.cyan.opacity(sample > 0.02 ? 0.85 : 0.3))
                    )
                }
            }
        }
        .frame(height: 64)
        .clipShape(RoundedRectangle(cornerRadius: Ataru.Radius.tile, style: .continuous))
        .background {
            // The resting control material, same as the un-filled call
            // buttons beside it, so the row reads as one family.
            RoundedRectangle(cornerRadius: Ataru.Radius.tile, style: .continuous)
                .fill(Color.white.opacity(0.09))
        }
        .overlay {
            RoundedRectangle(cornerRadius: Ataru.Radius.tile, style: .continuous)
                .strokeBorder(Theme.border, lineWidth: 1)
        }
        .opacity(isMuted ? 0.45 : 1)
        .animation(.easeInOut(duration: Ataru.Motion.micro), value: isMuted)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Your microphone")
        .accessibilityValue(isMuted ? "Muted" : (isLive ? "Live" : "Waiting"))
    }
}

/// The rolling buffer behind the waveform. A reference type so the Canvas
/// draw closure can append without touching SwiftUI state mid-render.
private final class LevelHistory {
    private(set) var samples: [Double] = Array(repeating: 0, count: 96)

    func push(_ level: Double) {
        samples.append(min(max(level, 0), 1))
        if samples.count > 96 { samples.removeFirst(samples.count - 96) }
    }
}

private struct CallControl: View {
    let symbol: String
    let label: String
    let foreground: Color
    var fill: Color?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 22))
                .foregroundStyle(foreground)
                .frame(width: 64, height: 64)
                .background { Circle().fill(fill ?? Color.white.opacity(0.09)) }
                .overlay {
                    if fill == nil {
                        Circle().strokeBorder(Theme.border, lineWidth: 1)
                    }
                }
        }
        .buttonStyle(CallPressStyle())
        .accessibilityLabel(label)
    }
}

/// The kit's press feedback: 0.92 over 0.08s.
private struct CallPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? Ataru.Motion.pressScale : 1)
            .animation(.easeOut(duration: Ataru.Motion.press), value: configuration.isPressed)
    }
}

/// The call while it is minimised: a full-width bar just above the tab bar.
///
/// A bar rather than a floating chip, so it reads the way a backgrounded call
/// does in the Phone app — a strip that belongs to the frame of the app, not a
/// widget sitting on the content. Deliberately still says what the assistant
/// is doing: a minimised call whose only content is "call in progress" has to
/// be restored to learn anything, which defeats minimising it.
struct MinimizedCallBar: View {
    @ObservedObject var call: CallService
    @ObservedObject var session: CallSessionModel
    let onExpand: () -> Void

    var body: some View {
        Button(action: onExpand) {
            HStack(spacing: Ataru.Space.md) {
                // A small orb, so the minimised call is recognisably the same
                // thing as the full screen rather than a generic banner.
                OrbView(phase: session.phase) { [weak session] in
                    session?.orbLevel ?? 0
                }
                .scaleEffect(0.30)
                .frame(width: 40, height: 40)
                .clipped()

                VStack(alignment: .leading, spacing: 1) {
                    Text("ATARU")
                        .font(.ataruBody())
                        .foregroundStyle(Theme.textPrimary)

                    Text(activity)
                        .ataruStyle(.meta)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                if case .active(let connectedAt) = call.state {
                    TimelineView(.periodic(from: connectedAt, by: 1)) { context in
                        Text(CallDuration.format(from: connectedAt, to: context.date))
                            .font(.ataruMono(11.5))
                            .foregroundStyle(Theme.textTertiary)
                            .monospacedDigit()
                    }
                }

                Image(systemName: "chevron.up")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, Ataru.Space.gutter)
            .frame(maxWidth: .infinity, minHeight: 56)
            .ataruCard(radius: Ataru.Radius.tile)
            .overlay {
                RoundedRectangle(cornerRadius: Ataru.Radius.tile, style: .continuous)
                    .strokeBorder(Theme.cyanSubdued.opacity(0.4), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Call with ATARU, \(activity)")
        .accessibilityHint("Double tap to return to the call.")
    }

    private var activity: String {
        if call.isMuted { return "muted" }
        switch session.phase {
        case .idle: return "connected"
        case .listening: return "listening"
        case .thinking: return "thinking"
        case .speaking: return "speaking"
        case .failed: return "problem"
        }
    }
}

/// `mm:ss`, growing to `h:mm:ss` only when it has to.
enum CallDuration {
    static func format(from start: Date, to end: Date) -> String {
        // Clamped: a clock change, or a connection timestamp a shade in the
        // future, should not render "-1:-3".
        let total = max(0, Int(end.timeIntervalSince(start)))
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }
}
