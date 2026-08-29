import AppIntents
import Foundation

/// "Hey Siri, ask ATARU what's on my calendar."
///
/// ## Why this is not SiriKit
///
/// The app already donates an `INStartCallIntent` so a contact card can dial
/// ATARU, and that is the whole of its Siri surface - a call, which means
/// unlocking the phone, waiting for the line, and holding a conversation. For
/// one question that is an enormous amount of ceremony.
///
/// `AppIntent` is the modern path and, unlike SiriKit's domain intents, it
/// needs NO `com.apple.developer.siri` entitlement: App Shortcuts are
/// discovered from the app's binary at install time. So this works on a build
/// signed with a plain development profile, which is the only kind this repo
/// can produce without `Config.xcconfig`.
///
/// ## Why it does not open the app
///
/// `openAppWhenRun = false` is the entire point. The answer is a single GET
/// against the vault and a sentence read back; foregrounding a SwiftUI app to
/// do that would put a screen in front of somebody who asked a question with
/// the phone face down on a desk.
struct AskATARUIntent: AppIntent {

    static var title: LocalizedStringResource = "Ask ATARU"

    static var description = IntentDescription(
        "Asks your ATARU assistant a question and reads the answer back.",
        categoryName: "Assistant",
        searchKeywords: ["ataru", "ask", "vault", "assistant"]
    )

    /// Answered in the background, out loud. See the type's doc comment.
    static var openAppWhenRun: Bool = false

    /// The question, as an entity rather than a `String`, AND THAT IS NOT A
    /// STYLE CHOICE.
    ///
    /// `AppShortcut` phrases may only interpolate a parameter whose type is an
    /// `AppEntity` or an `AppEnum`; a `String` parameter is refused outright by
    /// the AppIntents metadata processor at build time:
    ///
    ///     error: Invalid parameter type. AppEntity and AppEnum are the only
    ///     allowed types for question
    ///
    /// Without a parameter in the phrase there is no one-utterance form at all
    /// - "Hey Siri, ask ATARU" would always be answered by Siri stopping to ask
    /// what the question is, which is two round trips for one sentence.
    /// `QuestionEntity` exists to be the open-ended type the phrase grammar
    /// requires; its query hands back whatever was said, verbatim. See there.
    @Parameter(title: "Question",
               description: "What to ask ATARU.",
               requestValueDialog: "What should I ask ATARU?")
    var question: QuestionEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Ask ATARU \(\.$question)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let answer: String
        do {
            answer = try await ATARUIntentBackend.answer(to: question.text)
        } catch {
            // Spoken, not swallowed. A shortcut that fails silently is
            // indistinguishable from one that never ran, and the APIError
            // messages already say which of "not configured", "no route" and
            // "token rejected" happened.
            throw AskATARUError.backend(
                (error as? LocalizedError)?.errorDescription
                    ?? "ATARU couldn't be reached."
            )
        }
        // Returned as well as spoken, so the intent composes inside a Shortcut
        // - the answer can be pasted, sent on, or fed to another action.
        return .result(value: answer, dialog: IntentDialog(stringLiteral: answer))
    }
}

/// A spoken question, wrapped so the App Shortcuts phrase grammar will accept
/// it as a parameter. See `AskATARUIntent.question`.
struct QuestionEntity: AppEntity, Identifiable, Hashable {

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Question")
    static var defaultQuery = QuestionQuery()

    /// The question itself IS the identity. There is no catalogue of questions
    /// behind this - nothing is stored, nothing is looked up, and two identical
    /// questions are the same entity.
    var id: String { text }
    var text: String

    init(text: String) {
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(text)")
    }
}

/// Resolves any spoken text to a question, because any spoken text IS one.
///
/// An ordinary `EntityQuery` answers "which of my records did the user mean",
/// and that is the wrong shape here: there is no fixed set of questions to pick
/// from. `EntityStringQuery` is the variant Siri calls with the words it heard,
/// so returning exactly one entity built from those words is what turns the
/// entity requirement back into free-form dictation.
///
/// `suggestedEntities` is deliberately empty: an empty list means "no
/// catalogue", which is the truth, and it keeps the Shortcuts editor from
/// offering a picker where a text field belongs.
struct QuestionQuery: EntityStringQuery {

    func entities(matching string: String) async throws -> [QuestionEntity] {
        let question = QuestionEntity(text: string)
        return question.text.isEmpty ? [] : [question]
    }

    func entities(for identifiers: [QuestionEntity.ID]) async throws -> [QuestionEntity] {
        identifiers.map(QuestionEntity.init(text:)).filter { !$0.text.isEmpty }
    }

    func suggestedEntities() async throws -> [QuestionEntity] { [] }
}

/// A failure Siri can say out loud.
///
/// `CustomLocalizedStringResourceConvertible` is what makes the difference
/// between Siri reading the reason and Siri saying "Ask ATARU had a problem".
enum AskATARUError: Error, CustomLocalizedStringResourceConvertible {
    case backend(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .backend(let message):
            return LocalizedStringResource(stringLiteral: message)
        }
    }
}

/// The phrases iOS registers at install time.
///
/// Every phrase must contain `\(.applicationName)`, which resolves to "ATARU"
/// and to any alternative names declared in an `AppShortcuts.strings`. The
/// parameterised forms are what make a whole question work in ONE utterance -
/// "Hey Siri, ask ATARU what's on my calendar" - rather than Siri stopping to
/// ask what the question is. The bare forms are the deliberate fallback: said
/// on their own they trigger `requestValueDialog`, so "Hey Siri, ask ATARU"
/// still works and Siri asks what to ask.
struct ATARUAppShortcuts: AppShortcutsProvider {

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskATARUIntent(),
            phrases: [
                "Ask \(.applicationName)",
                "Ask \(.applicationName) \(\.$question)",
                "Ask \(.applicationName) about \(\.$question)",
                "\(.applicationName)",
                "\(.applicationName) \(\.$question)",
            ],
            shortTitle: "Ask ATARU",
            systemImageName: "waveform"
        )
    }
}
