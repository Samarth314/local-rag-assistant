import SwiftUI

/// The record control, and the live transcript while it runs.
///
/// Deliberately not a sheet. A sheet would cover the notes the user is
/// speaking about, and dismissing one mid-recording is an easy accident with
/// an expensive outcome. This grows out of the bottom of the screen instead:
/// a button when idle, a panel while recording, back to a button when done.
struct NoteRecorderBar: View {
    @ObservedObject var recorder: NoteRecorder
    let onSave: (Note) -> Void

    /// Redrawn once a second while recording, for the timer. Deliberately not
    /// a TimelineView: this sits over a screen XCUITest has to drive, and a
    /// view that animates forever is a screen that never goes idle (the orb
    /// taught us that one - see OrbView).
    @State private var tick = Date()
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: Theme.Space.s) {
            if recorder.phase == .recording {
                liveTranscript
            }
            if case .failed(let message) = recorder.phase {
                Text(message)
                    .font(.ataruCaption())
                    .foregroundStyle(Theme.amber)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Theme.Space.m)
            }
            controls
        }
        .padding(.horizontal, Theme.Space.screen)
        .padding(.bottom, Theme.Space.s)
        .background(alignment: .bottom) {
            // Keeps the list legible as it scrolls behind the controls.
            LinearGradient(colors: [Ataru.Palette.bg.opacity(0), Ataru.Palette.bg],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 160)
                .allowsHitTesting(false)
                .ignoresSafeArea()
        }
        .onReceive(timer) { now in
            if recorder.phase == .recording { tick = now }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.86), value: recorder.phase)
    }

    // MARK: - Pieces

    private var liveTranscript: some View {
        ScrollView {
            Text(recorder.partial.nilIfBlank ?? "Listening…")
                .font(.ataruBody())
                .foregroundStyle(recorder.partial.nilIfBlank == nil
                                 ? Theme.textTertiary : Theme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Theme.Space.m)
        }
        .frame(maxHeight: 140)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.large,
                                                        style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                .strokeBorder(Theme.border, lineWidth: 1)
        }
    }

    private var controls: some View {
        HStack(spacing: Theme.Space.m) {
            if recorder.phase == .recording {
                Button {
                    recorder.cancel()
                } label: {
                    Text("Discard")
                        .font(.ataruLabel())
                        .foregroundStyle(Theme.textSecondary)
                        .hitTarget()
                }
                .accessibilityIdentifier("discard-note")

                Spacer(minLength: 0)

                Text(elapsedLabel)
                    .font(.ataruMono(14))
                    .foregroundStyle(Theme.cyan)
                    .monospacedDigit()
                    .accessibilityLabel("Recording time")
            }

            Spacer(minLength: 0)

            recordButton
        }
        .frame(maxWidth: .infinity)
    }

    private var recordButton: some View {
        Button {
            Task {
                switch recorder.phase {
                case .recording:
                    if let note = await recorder.finish() { onSave(note) }
                default:
                    await recorder.start()
                }
            }
        } label: {
            ZStack {
                Circle()
                    .fill(Ataru.metal)
                    .overlay { Circle().strokeBorder(Theme.cyanSubdued, lineWidth: 1) }
                    .frame(width: 64, height: 64)

                if recorder.phase == .transcribing {
                    ProgressView().tint(Theme.cyan)
                } else {
                    // A circle that squares off while running: the universal
                    // record/stop pair, and readable at a glance from across
                    // a room in a way a changing colour is not.
                    RoundedRectangle(cornerRadius: recorder.phase == .recording ? 4 : 13,
                                     style: .continuous)
                        .fill(recorder.phase == .recording ? Theme.amber : Theme.cyan)
                        .frame(width: 26, height: 26)
                }
            }
            // A quiet pulse on the ring while the mic is live, driven by the
            // actual input level, so silence looks different from speech.
            .overlay {
                if recorder.phase == .recording {
                    Circle()
                        .strokeBorder(Theme.cyan.opacity(0.35), lineWidth: 2)
                        .frame(width: 64 + CGFloat(recorder.level) * 26,
                               height: 64 + CGFloat(recorder.level) * 26)
                        .animation(.easeOut(duration: 0.12), value: recorder.level)
                }
            }
        }
        .disabled(recorder.phase == .transcribing)
        .accessibilityIdentifier("record-note")
        .accessibilityLabel(recorder.phase == .recording ? "Stop recording" : "Record a note")
    }

    private var elapsedLabel: String {
        // `tick` is read so the timer's republish actually redraws this.
        _ = tick
        let total = Int(recorder.elapsed)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
