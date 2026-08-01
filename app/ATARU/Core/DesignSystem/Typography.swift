import SwiftUI

/// Typographic roles, forwarding to the UI kit's `Ataru.TextStyle`.
///
/// The kit's sizes are not round numbers — body is 15.5, meta 11.5 — and its
/// weights run lighter than iOS defaults. Both are deliberate, so these map
/// straight through rather than being re-picked here.
///
/// Where tracking or colour also matter (the all-caps micro labels especially,
/// which need their 0.28em to read at all), prefer `.ataruStyle(_:)` over these
/// — it applies font, tracking and colour together.
extension Font {
    /// The wordmark. Ultra-light with wide tracking.
    static func ataruBrand() -> Font { Ataru.TextStyle.brand.font }
    /// Large screen title.
    static func ataruDisplay() -> Font { Ataru.TextStyle.greeting.font }
    /// Section heading inside a screen.
    static func ataruTitle() -> Font { .system(size: 24, weight: .thin) }
    /// Uppercase tracked micro-label: SYSTEM, HEALTH, MORNING.
    static func ataruLabel() -> Font { Ataru.TextStyle.eyebrow.font }
    /// Standard reading text.
    static func ataruBody() -> Font { Ataru.TextStyle.body.font }
    /// Secondary/supporting text.
    static func ataruCaption() -> Font { Ataru.TextStyle.meta.font }
    /// Hint text under a control.
    static func ataruHint() -> Font { Ataru.TextStyle.hint.font }
    /// Telemetry and metadata numerals. Tabular so columns of figures line up.
    static func ataruMono(_ size: CGFloat = 11.5) -> Font {
        .system(size: size, weight: .regular, design: .monospaced)
    }
}

/// An uppercase, widely tracked section label — a core part of the ATARU voice.
///
/// Uses the kit's `eyebrow` style, whose 0.28em tracking is what makes it read
/// as a label rather than as small body text.
struct SectionLabel: View {
    let text: String
    var color: Color?

    init(text: String, color: Color? = nil) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text.uppercased())
            .ataruStyle(.eyebrow)
            .foregroundStyle(color ?? Ataru.TextStyle.eyebrow.color)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The wordmark, with its trailing period in the accent — the one place the
/// kit spends the accent on something decorative.
struct Wordmark: View {
    var body: some View {
        HStack(spacing: 0) {
            Text("ATARU").ataruStyle(.brand)
            Text(".").ataruStyle(.brand).foregroundStyle(Theme.cyan)
        }
        .accessibilityElement()
        .accessibilityLabel("ATARU")
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 20) {
        Wordmark()
        SectionLabel(text: "Library")
        Text("Good evening.").ataruStyle(.greeting)
        Text("Answers come from your own indexed documents.").ataruStyle(.body)
        Text("14 documents · indexed 2 h ago").ataruStyle(.meta)
        Text("Hold to speak").ataruStyle(.hint)
    }
    .padding(Theme.Space.screen)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    .ataruBackdrop()
}
