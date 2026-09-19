import SwiftUI

/// The orb, small, on a page that is not Ask.
///
/// ## Why this exists
///
/// The Files browser is the first screen in the app where the fastest way to
/// change what is on it is to say so: "just the 2025 spreadsheets" is one
/// sentence and four taps. The Ask page's orb is the whole point of that page
/// and cannot move; this is the same control, the same voice path, and the
/// same phase machine, sized for a corner.
///
/// ## What it is NOT
///
/// It is not a second assistant. It runs its own `VoiceViewModel` because the
/// Ask page's is private to that view, but the microphone is shared hardware
/// and two open recognisers hearing one room is a real failure mode - so
/// taking the mic here PAUSES the Ask page's "Hey ATARU" standby for the
/// duration (see `.ataruDockedMicTaken`) and gives it back on release. The big
/// orb is untouched.
///
/// ## Reusable on purpose
///
/// Nothing in here knows about files. It hands the answer back through
/// `onAnswer` and lets the page decide, so the next tile that wants a voice
/// affordance adds a modifier rather than a copy of this file.
struct DockedOrb: View {
    @ObservedObject var model: VoiceViewModel
    /// The spoken answer, once the turn has one, so the page can caption it.
    ///
    /// Only that. A document the turn resolved is already on the model's own
    /// `presentedDocument`, and a listing has already been handed to the route
    /// latch by the model - reporting either of those here as well would open
    /// them twice.
    var onAnswer: (String) -> Void

    var side: CGFloat = 58

    /// Mirrors the Ask orb's guard exactly: `onChanged` fires per touch
    /// report, and `beginListening` is async, so without this every report in
    /// the opening window starts another concurrent open of the microphone.
    @State private var isStartingListen = false
    @State private var lastRoutedExchange: String?

    var body: some View {
        OrbView(phase: model.phase, side: side) { [weak model] in
            model?.orbLevel ?? 0
        }
        .frame(width: side, height: side)
        .background {
            Circle()
                .fill(Theme.surfaceElevated.opacity(0.9))
                .overlay { Circle().strokeBorder(Theme.border, lineWidth: 1) }
                .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
                .padding(-4)
        }
        .contentShape(Circle())
        // The radial launcher must not open a third of a second into a held
        // question, exactly as on the Ask page.
        .pressMenuExclusion()
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !isStartingListen, model.canRecord,
                          model.phase != .listening else { return }
                    isStartingListen = true
                    NotificationCenter.default.post(name: .ataruDockedMicTaken,
                                                    object: nil)
                    Task {
                        await model.beginListening()
                        isStartingListen = false
                    }
                }
                .onEnded { _ in
                    isStartingListen = false
                    model.endListening()
                    NotificationCenter.default.post(name: .ataruDockedMicReleased,
                                                    object: nil)
                }
        )
        .accessibilityElement()
        .accessibilityLabel("Ask about this page")
        .accessibilityHint("Double tap to start listening, then double tap again to send.")
        .accessibilityAction {
            // VoiceOver cannot hold, so it toggles - the same fallback the
            // big orb has.
            if model.phase == .listening {
                model.endListening()
                NotificationCenter.default.post(name: .ataruDockedMicReleased, object: nil)
            } else {
                NotificationCenter.default.post(name: .ataruDockedMicTaken, object: nil)
                Task { await model.beginListening() }
            }
        }
        // The answer, once it exists. Keyed on the exchange id so one turn is
        // reported once, however many times this view redraws.
        .onChange(of: model.exchanges.first?.id) { _, id in
            guard let id, id != lastRoutedExchange,
                  let exchange = model.exchanges.first else { return }
            lastRoutedExchange = id
            // A turn that pulled a file up is about to present it; a caption
            // repeating "Opening X" over the viewer is noise.
            guard exchange.document == nil else { return }
            onAnswer(exchange.answer)
        }
    }
}

/// A transient line of answer text over a page.
///
/// Not a card and not a sheet: the answer to "how many of those are PDFs" is
/// one sentence and belongs on top of the thing it is about, for as long as it
/// takes to read. Dismissable by tap, and it clears itself.
struct DockedOrbCaption: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        Text(text)
            .font(.ataruCaption())
            .foregroundStyle(Theme.textPrimary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, Theme.Space.s)
            .padding(.vertical, Theme.Space.xs)
            .background {
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .fill(Theme.surfaceElevated)
                    .overlay {
                        RoundedRectangle(cornerRadius: Theme.Radius.card,
                                         style: .continuous)
                            .strokeBorder(Theme.border, lineWidth: 1)
                    }
            }
            .onTapGesture(perform: dismiss)
            .accessibilityAddTraits(.isStaticText)
    }
}
