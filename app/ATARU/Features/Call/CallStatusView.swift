import SwiftUI

/// What the app shows while a call is up.
///
/// ## Why this exists at all
///
/// CallKit brings the app to the foreground when a call is answered. That is
/// not configurable and never has been — it has been CallKit's behaviour since
/// iOS 10, and Apple's position is that it is fundamental to how the framework
/// works. So the app *will* appear, whatever we would prefer.
///
/// Given that, the choice is only ever what it appears as. Before this, it
/// foregrounded into the Ask tab, which reads as the app opening for no reason
/// — the screen actively lying about what the device is doing.
///
/// ## What this deliberately is not
///
/// Not a call UI. There is no mute button, no hang-up button, no keypad. Every
/// control stays in the system call interface where it belongs: the green pill
/// in the status bar, the lock screen, CarPlay, the Apple Watch. Duplicating
/// them here would mean two sets of controls that can disagree, and the system
/// set is the one that works when the phone is locked.
///
/// This is a status readout and nothing more.
struct CallStatusView: View {
    @ObservedObject var call: CallService
    @ObservedObject var session: CallSessionModel

    var body: some View {
        VStack(spacing: Ataru.Space.lg) {
            Spacer(minLength: 0)

            Text("ATARU")
                .font(.system(size: 34, weight: .thin))
                .tracking(34 * 0.03)
                .foregroundStyle(Theme.textPrimary)

            OrbView(phase: session.phase, level: session.dictation.level)

            Text(statusLabel.uppercased())
                .ataruStyle(.callState)
                .contentTransition(.opacity)
                .animation(.easeInOut(duration: Ataru.Motion.micro), value: statusLabel)

            elapsed

            Spacer(minLength: 0)

            transcript

            Spacer(minLength: 0)

            // Points at the real controls rather than growing a second set.
            Text("Mute and hang up are in the call controls at the top of the screen.")
                .ataruStyle(.hint)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Ataru.Space.xl)
        }
        .padding(.horizontal, Ataru.Space.gutter)
        .padding(.bottom, Ataru.Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ataruBackdrop()
        .accessibilityElement(children: .contain)
    }

    private var statusLabel: String {
        switch call.state {
        case .active:
            switch session.phase {
            case .idle: return "Connected"
            case .listening: return "Listening"
            case .thinking: return "Searching your files"
            case .speaking: return "Speaking"
            case .failed: return "Problem"
            }
        default:
            return call.state.label
        }
    }

    @ViewBuilder
    private var elapsed: some View {
        if case .active(let connectedAt) = call.state {
            TimelineView(.periodic(from: connectedAt, by: 1)) { context in
                Text(CallDuration.format(from: connectedAt, to: context.date))
                    .font(.ataruMono(11.5))
                    .foregroundStyle(Theme.textTertiary)
                    .monospacedDigit()
            }
            // The system call UI already announces duration; a second timer
            // read aloud on every tick is noise.
            .accessibilityHidden(true)
        }
    }

    private var transcript: some View {
        VStack(spacing: Ataru.Space.md) {
            Text(session.heard.isEmpty ? " " : session.heard)
                .ataruStyle(.callTranscript)
                .multilineTextAlignment(.center)
                .lineLimit(3)

            if !session.answer.isEmpty, session.phase != .listening {
                Text(session.answer)
                    .ataruStyle(.callAnswer)
                    .multilineTextAlignment(.center)
                    .lineLimit(6)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.easeInOut(duration: 0.2), value: session.answer)
    }
}

/// `mm:ss`, growing to `h:mm:ss` only when it has to.
enum CallDuration {
    static func format(from start: Date, to end: Date) -> String {
        // Clamped: a clock change, or a connection timestamp a shade in the
        // future, should not render "-1:-3".
        let total = max(0, Int(end.timeIntervalSince(start)))
        let seconds = total % 60
        let minutes = (total / 60) % 60
        let hours = total / 3600
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }
}
