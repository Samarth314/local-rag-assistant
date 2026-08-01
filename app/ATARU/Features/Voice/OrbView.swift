import SwiftUI

/// The ATARU orb.
///
/// One control that is also the entire status display: its motion says what
/// the assistant is doing, so the screen needs no spinner and no status text
/// competing for attention. It breathes when idle, tracks the microphone while
/// listening, rotates while thinking, and pulses while speaking.
///
/// Every animation is suppressed under Reduce Motion, where the phase is
/// carried by colour and the label instead.
struct OrbView: View {
    let phase: VoicePhase
    /// Live microphone level, 0...1. Only meaningful while listening.
    var level: Double = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathe = false
    @State private var spin = false

    /// Per-state orb tint, taken from the kit's `orb.states[*].col`.
    ///
    /// Every state is a variant of the accent — the kit shifts hue by a few
    /// degrees per state rather than changing colour. Speaking used to be green
    /// and thinking amber, which made the orb the app's second and third accent
    /// and read as status ("green = fine, amber = warning") when it only ever
    /// meant "the assistant is talking".
    private var tone: Color {
        switch phase {
        case .idle:      return Color(hex: 0x8FD3E6)   // 143, 211, 230
        case .listening: return Color(hex: 0x96DCF0)   // 150, 220, 240
        case .thinking:  return Color(hex: 0xAFC8EB)   // 175, 200, 235
        case .speaking:  return Color(hex: 0xA0DCEE)   // 160, 220, 238
        // Not in the kit's orb table: a failure is the one case where the
        // palette's error colour is more use than staying on-accent.
        case .failed:    return Theme.red
        }
    }

    /// Listening scales with the user's voice; the other phases have a fixed
    /// resting size so the orb never looks like it is reacting to nothing.
    private var scale: CGFloat {
        switch phase {
        case .listening: return 1.0 + CGFloat(level) * 0.22
        case .speaking: return breathe ? 1.06 : 1.0
        case .idle: return breathe ? 1.03 : 1.0
        default: return 1.0
        }
    }

    var body: some View {
        ZStack {
            // Bloom. Kept faint: this is illumination, not neon.
            Circle()
                .fill(
                    RadialGradient(colors: [tone.opacity(0.34), .clear],
                                   center: .center, startRadius: 4, endRadius: 130)
                )
                .frame(width: 260, height: 260)
                .blur(radius: 12)

            Circle()
                .strokeBorder(tone.opacity(0.28), lineWidth: 1)
                .frame(width: 176, height: 176)

            // Thinking: a single arc rotating around the rim.
            Circle()
                .trim(from: 0, to: 0.16)
                .stroke(tone, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .frame(width: 176, height: 176)
                .rotationEffect(.degrees(spin ? 360 : 0))
                .opacity(phase == .thinking ? 1 : 0)

            Circle()
                .fill(
                    RadialGradient(colors: [tone.opacity(0.30), tone.opacity(0.06)],
                                   center: .center, startRadius: 2, endRadius: 84)
                )
                .frame(width: 148, height: 148)
                .overlay { Circle().strokeBorder(tone.opacity(0.5), lineWidth: 1) }

            Image(systemName: symbol)
                .font(.system(size: 30, weight: .ultraLight))
                .foregroundStyle(tone)
        }
        .scaleEffect(reduceMotion ? 1.0 : scale)
        .animation(.easeOut(duration: 0.12), value: level)
        .animation(.easeInOut(duration: 0.35), value: phase)
        .onAppear { startAnimations() }
        .onChange(of: phase) { _, _ in startAnimations() }
        .accessibilityElement()
        .accessibilityLabel("ATARU")
        .accessibilityValue(phase.label)
    }

    private var symbol: String {
        switch phase {
        case .idle: return "waveform"
        case .listening: return "mic"
        case .thinking: return "ellipsis"
        case .speaking: return "speaker.wave.2"
        case .failed: return "exclamationmark"
        }
    }

    private func startAnimations() {
        guard !reduceMotion else { return }
        breathe = false
        spin = false
        withAnimation(.easeInOut(duration: 2.6).repeatForever(autoreverses: true)) {
            breathe = true
        }
        if phase == .thinking {
            withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) {
                spin = true
            }
        }
    }
}

#Preview {
    VStack(spacing: 40) {
        OrbView(phase: .idle)
        OrbView(phase: .thinking)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .ataruBackdrop()
}
