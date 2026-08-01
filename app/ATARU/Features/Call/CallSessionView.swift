import SwiftUI

/// What the app shows while a call with ATARU is up.
///
/// ## The idea it borrows
///
/// A voice-channel UI works because it answers one question at a glance: *who
/// is talking right now*. Two participants, each lit when they hold the floor.
/// That is the useful part, and it maps cleanly onto a call with an assistant —
/// exactly one of you is ever speaking, and knowing which removes the awkward
/// "did it hear me, should I repeat myself" pause that otherwise dominates
/// talking to a machine.
///
/// ## What it does not borrow
///
/// None of the look. No avatar grid, no green speaking ring, no floating
/// control bar. Those read as a specific product, and ATARU is not that
/// product. The two participants are the kit's milled cards, the active one is
/// marked with the single accent, and the whole thing sits on the call
/// backdrop.
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
        VStack(spacing: Ataru.Space.lg) {
            minimizeBar

            header

            // Orb, then what is being said, then who is saying it. The words
            // sit directly under the orb because that is where the eye already
            // is — the orb is what moves, so anything further away gets missed
            // while someone is mid-sentence.
            OrbView(phase: session.phase, level: session.dictation.level)

            transcript
                .frame(maxHeight: .infinity)

            participants

            controls
        }
        .padding(.horizontal, Ataru.Space.gutter)
        .padding(.top, Ataru.Space.md)
        .padding(.bottom, Ataru.Space.xl)
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
            case .thinking: return "Looking through your files"
            case .speaking: return "Answering"
            case .failed: return "Something went wrong"
            }
        default:
            return call.state.label
        }
    }

    // MARK: - Participants

    /// Who is in the call, and who currently has the floor.
    private var participants: some View {
        HStack(spacing: Ataru.Space.md) {
            ParticipantTile(
                name: "You",
                symbol: call.isMuted ? "mic.slash" : "waveform",
                caption: youCaption,
                isActive: session.phase == .listening && !call.isMuted,
                // Drives a ring that tracks the actual voice, so a silent room
                // and a room the mic cannot hear look different.
                level: session.phase == .listening ? session.dictation.level : 0
            )

            ParticipantTile(
                name: "ATARU",
                symbol: ataruSymbol,
                caption: ataruCaption,
                isActive: session.phase == .thinking || session.phase == .speaking,
                // No input level for the assistant: it is either holding the
                // floor or it is not, and a fake waveform would be a lie.
                level: session.phase == .speaking ? 0.7 : 0
            )
        }
    }

    private var youCaption: String {
        if call.isMuted { return "Muted" }
        return session.phase == .listening ? "Speaking" : "Listening for you"
    }

    private var ataruSymbol: String {
        switch session.phase {
        case .thinking: return "ellipsis"
        case .speaking: return "speaker.wave.2"
        default: return "sparkle"
        }
    }

    private var ataruCaption: String {
        switch session.phase {
        case .thinking: return "Searching"
        case .speaking: return "Speaking"
        case .failed: return "Problem"
        default: return "Waiting"
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
        HStack(spacing: Ataru.Space.lg) {
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

/// One side of the conversation.
///
/// The active one is marked with the accent and a ring that grows with voice
/// level. Everything else stays the resting card, so at a glance the lit tile
/// is the one holding the floor.
private struct ParticipantTile: View {
    let name: String
    let symbol: String
    let caption: String
    let isActive: Bool
    let level: Double

    var body: some View {
        VStack(spacing: Ataru.Space.sm) {
            ZStack {
                // Grows with the voice. Sits behind the glyph so a loud moment
                // reads as the tile breathing rather than the icon jumping.
                Circle()
                    .strokeBorder(Theme.cyan.opacity(0.35), lineWidth: 1)
                    .frame(width: 54, height: 54)
                    .scaleEffect(1 + CGFloat(min(max(level, 0), 1)) * 0.35)
                    .opacity(isActive ? 1 : 0)
                    .animation(.easeOut(duration: 0.12), value: level)

                Image(systemName: symbol)
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(isActive ? Theme.cyan : Theme.textSecondary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .frame(height: 76)

            Text(name)
                .font(.ataruBody())
                .foregroundStyle(Theme.textPrimary)

            Text(caption)
                .ataruStyle(.meta)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Ataru.Space.md)
        .ataruCard(radius: Ataru.Radius.tile)
        .overlay {
            // The accent is what marks the active speaker — the kit's one
            // accent doing the job it exists for.
            RoundedRectangle(cornerRadius: Ataru.Radius.tile, style: .continuous)
                .strokeBorder(Theme.cyan.opacity(isActive ? 0.55 : 0), lineWidth: 1)
        }
        .animation(.easeInOut(duration: Ataru.Motion.micro), value: isActive)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name), \(caption)")
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

/// The call while it is minimised: a card above the tab bar.
///
/// Sits bottom-right, just clear of the tabs, where a thumb already is and
/// where it covers the least content. Deliberately still says what the
/// assistant is doing — a minimised call whose only content is "call in
/// progress" has to be restored to learn anything, which defeats minimising it.
struct MinimizedCallBar: View {
    @ObservedObject var call: CallService
    @ObservedObject var session: CallSessionModel
    let onExpand: () -> Void

    var body: some View {
        Button(action: onExpand) {
            HStack(spacing: Ataru.Space.md) {
                // A small orb, so the minimised call is recognisably the same
                // thing as the full screen rather than a generic banner.
                OrbView(phase: session.phase, level: session.dictation.level)
                    .scaleEffect(0.32)
                    .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: 2) {
                    Text("ATARU")
                        .font(.ataruBody())
                        .foregroundStyle(Theme.textPrimary)

                    HStack(spacing: Ataru.Space.xs) {
                        Text(activity)
                            .ataruStyle(.meta)
                            .lineLimit(1)

                        if case .active(let connectedAt) = call.state {
                            TimelineView(.periodic(from: connectedAt, by: 1)) { context in
                                Text(CallDuration.format(from: connectedAt, to: context.date))
                                    .font(.ataruMono(11))
                                    .foregroundStyle(Theme.textTertiary)
                                    .monospacedDigit()
                            }
                        }
                    }
                }

                Image(systemName: "chevron.up")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.leading, Ataru.Space.xs)
            }
            .padding(.horizontal, Ataru.Space.md)
            .padding(.vertical, Ataru.Space.sm)
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
        case .thinking: return "searching"
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
