import Foundation
import NaturalLanguage

/// A dictated note, reduced to a summary and a list of points.
///
/// ## Why this does not ask the assistant
///
/// The obvious implementation is to send the transcript to ATARU and let the
/// model write the summary, and that is deliberately not what happens. Talking
/// at a notes app is not asking a question: the recording must not turn into a
/// prompt, must not produce an answer, and must not depend on the Orin being
/// reachable — a note taken in a lift with no signal is still a note. So the
/// microphone path ends at transcription (the same recogniser the orb uses)
/// and everything below is local text processing.
///
/// That constrains what the summary can be. This is *extractive*: it picks the
/// sentences that already carry the most of what was said, rather than writing
/// new ones. An abstractive summary would read better and would need the model.
/// The tradeoff is taken knowingly, and it is the one that keeps a note a note.
struct NoteDigest: Hashable, Codable {
    /// One to three sentences, in the order they were spoken.
    var summary: String
    /// Every point, in order.
    var bullets: [String]

    var isEmpty: Bool { summary.isEmpty && bullets.isEmpty }

    // MARK: - Building

    static func make(from transcript: String) -> NoteDigest {
        let sentences = points(in: transcript)
        guard !sentences.isEmpty else { return NoteDigest(summary: "", bullets: []) }

        return NoteDigest(summary: summary(of: sentences), bullets: sentences)
    }

    /// A spoken point, cut down to something that reads as a to-do.
    ///
    /// People do not dictate in list form. They say "um so I need to call the
    /// landlord about the boiler before Friday because the heating is broken",
    /// and the item worth ticking is "Call the landlord about the boiler". Two
    /// cuts get most of the way there: the self-reference and modal at the
    /// front ("I need to", "remember to", "make sure I"), which is scaffolding
    /// every item would otherwise repeat, and the explanation at the back
    /// ("because…", "since…"), which is why the task exists rather than what
    /// it is.
    ///
    /// Length is the last resort, not the method, and it never truncates
    /// mid-thought: a title cut to "Call the landlord about the…" is worse
    /// than one word over budget. It cuts at a preposition or not at all.
    static func condense(_ point: String) -> String {
        var text = point.trimmingCharacters(in: .whitespacesAndNewlines)

        var strippedSomething = true
        while strippedSomething {
            strippedSomething = false
            for opener in openers {
                guard text.lowercased().hasPrefix(opener + " ") else { continue }
                text = String(text.dropFirst(opener.count + 1))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                strippedSomething = true
            }
        }

        // The reason, not the task.
        for tail in reasonSeams {
            guard let range = text.lowercased().range(of: tail) else { continue }
            let head = String(text[text.startIndex..<range.lowerBound])
                .trimmingCharacters(in: CharacterSet(charactersIn: " ,;:"))
            if head.split(separator: " ").count >= 2 { text = head }
        }

        text = text.trimmingCharacters(in: CharacterSet(charactersIn: " .,;:"))
        if text.split(separator: " ").count > maxWordsPerTitle {
            text = trimmedAtAPreposition(text)
        }
        guard let first = text.first else { return point }
        return first.uppercased() + text.dropFirst()
    }

    /// Cuts before a trailing prepositional phrase, when that leaves something
    /// still worth reading. Otherwise leaves the text long.
    private static func trimmedAtAPreposition(_ text: String) -> String {
        let words = text.split(separator: " ").map(String.init)
        for index in stride(from: min(words.count - 1, maxWordsPerTitle), through: 3, by: -1) {
            guard prepositions.contains(words[index].lowercased()) else { continue }
            return words[0..<index].joined(separator: " ")
        }
        return text
    }

    /// Scaffolding that every dictated item repeats. Longest first, so "i need
    /// to" is not half-eaten by "i".
    private static let openers = [
        "i really need to", "i also need to", "i just need to",
        "don't forget to", "dont forget to", "make sure that i", "make sure i",
        "make sure to", "i'm going to", "im going to", "i am going to",
        "i've got to", "ive got to", "i have got to", "i have to", "i need to",
        "i should also", "i should", "i must", "i want to", "i will", "i'll",
        "we need to", "we should", "we have to", "we'll", "remember to",
        "need to", "have to", "got to", "gotta", "should", "must"
    ]

    /// What follows these is why, not what.
    private static let reasonSeams = [
        " because ", " since ", " so that ", " otherwise ", " in order to ",
        " which means ", " that way "
    ]

    private static let prepositions: Set<String> = [
        "about", "for", "with", "at", "on", "in", "by", "from", "before",
        "after", "until", "till", "regarding", "re"
    ]

    private static let maxWordsPerTitle = 8

    /// Splits dictation into the points it contains.
    ///
    /// Sentence tokenisation alone is not enough. Dictation punctuates
    /// unevenly — speak for two minutes and Apple may return the lot as one
    /// sentence — so anything still overlong afterwards is split again at the
    /// words people actually use to move on ("and then", "also", "next"). A
    /// forty-word bullet is not a bullet.
    static func points(in transcript: String) -> [String] {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }

        var raw: [String] = []
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            raw.append(String(text[range]))
            return true
        }
        if raw.isEmpty { raw = [text] }

        var out: [String] = []
        for sentence in raw {
            for piece in split(long: sentence) {
                guard let cleaned = tidy(piece) else { continue }
                // Dictation repeats itself when it revises a phrase mid-flow.
                // Compared case- and punctuation-insensitively, because "Call
                // Arya." and "call Arya" are the same point said twice.
                let key = comparisonKey(cleaned)
                if out.contains(where: { comparisonKey($0) == key }) { continue }
                out.append(cleaned)
            }
        }
        return out
    }

    /// The executive summary: the highest-scoring sentences, kept in the order
    /// they were spoken so the summary still reads as a sequence.
    ///
    /// Classic term-frequency extraction — a sentence scores by how much of the
    /// note's own vocabulary it carries, averaged over its length so a rambling
    /// one does not win merely by being long.
    /// The summary, or nothing at all.
    ///
    /// ## Why this is often empty now
    ///
    /// This is extractive: it can only pick sentences the note already
    /// contains. On a short note that is not a summary, it is the note typed
    /// out twice — which is exactly what it looked like, because that is
    /// exactly what it was. The previous version made it worse by design,
    /// returning the whole note verbatim whenever there were two points or
    /// fewer.
    ///
    /// An honest extractive summary has to earn its place, so it appears only
    /// when it is a real reduction: enough points that picking a few is a
    /// choice, and a result meaningfully shorter than the note it came from.
    /// Below that the list IS the note, and the screen shows the list.
    ///
    /// Writing a genuinely new sentence is abstractive and needs the model —
    /// available now that `/api/parse-tasks` exists, and deliberately not
    /// wired here, because a note must still work with the Orin unreachable.
    private static func summary(of sentences: [String]) -> String {
        // Fewer than this and any extract is most of the note.
        guard sentences.count >= minimumPointsForSummary else { return "" }

        var frequency: [String: Int] = [:]
        for sentence in sentences {
            for word in terms(in: sentence) { frequency[word, default: 0] += 1 }
        }
        guard let peak = frequency.values.max(), peak > 0 else {
            return sentences[0]
        }

        let scored = sentences.enumerated().map { index, sentence -> (Int, Double) in
            let words = terms(in: sentence)
            guard !words.isEmpty else { return (index, 0) }
            let weight = words.reduce(0.0) {
                $0 + Double(frequency[$1] ?? 0) / Double(peak)
            } / Double(words.count)
            // A small nudge toward the opening. People say what a note is
            // about before they say the details, and an overview that starts
            // in the middle reads as though it began mid-thought.
            let lead = index == 0 ? 0.12 : 0
            return (index, weight + lead)
        }

        // A third of the note, between one and three sentences: enough to be
        // an overview of a long note, never so much that it repeats it.
        let wanted = min(3, max(1, sentences.count / 3))
        let chosen = scored.sorted { $0.1 > $1.1 }
            .prefix(wanted)
            .map(\.0)
            .sorted()

        let extract = chosen.map { sentences[$0] }.joined(separator: " ")
        // The last guard, and the one that catches the case the count test
        // cannot: five points can still be five short ones, where "a third of
        // them" is half the characters. If it is not a reduction it is a
        // repeat, and a repeat is worth less than the space it takes.
        let whole = sentences.joined(separator: " ")
        guard Double(extract.count) <= Double(whole.count) * maximumSummaryShare else {
            return ""
        }
        return extract
    }

    /// Below this many points, the list is the note and no extract is a
    /// summary of it.
    private static let minimumPointsForSummary = 5
    /// An extract longer than this share of the note is a repeat.
    private static let maximumSummaryShare = 0.6

    // MARK: - Text

    /// Splits one tokenised sentence into the points it actually contains.
    ///
    /// Two passes, and the distinction between them is the whole of this
    /// function. Some phrases mean "new point" wherever they appear — "and
    /// then", "after that", "next" — and splitting on those must NOT wait for
    /// the sentence to be long, because the case this feature exists for is
    /// unpunctuated dictation, which arrives as one sentence of any length.
    /// "Call the landlord and then book the dentist" is two points at twelve
    /// words. Others — a bare "and", "but", "so" — join clauses far more often
    /// than they start points, so those only apply once a piece is too long to
    /// read as a bullet, where the risk of a clumsy split beats the certainty
    /// of a paragraph.
    ///
    /// Every split must leave both halves substantial. Without that, "I also
    /// need milk" splits into "I" and "need milk", and the orphan is dropped by
    /// `tidy` — losing a word out of the middle of the user's note, which is
    /// worse than not splitting at all.
    private static func split(long sentence: String) -> [String] {
        if let parts = divide(sentence, on: strongSeams) {
            return parts.flatMap { split(long: $0) }
        }
        guard sentence.split(separator: " ").count > maxWordsPerPoint else {
            return [sentence]
        }
        if let parts = divide(sentence, on: weakSeams) {
            return parts.flatMap { split(long: $0) }
        }
        return [sentence]
    }

    /// The first seam that divides this text into parts worth keeping.
    private static func divide(_ text: String, on seams: [String]) -> [String]? {
        for seam in seams {
            let parts = text.components(separatedBy: seam)
            guard parts.count > 1 else { continue }
            let substantial = parts.allSatisfy {
                $0.split(separator: " ").count >= minWordsPerPart
            }
            guard substantial else { continue }
            return parts
        }
        return nil
    }

    /// Longest first, so " and then " is never consumed by " and ".
    private static let strongSeams = [
        ", and then ", " and then ", ", after that ", " after that ",
        ", also ", " also ", ", next ", " next "
    ]
    private static let weakSeams = [", but ", ", so ", ", and ", " but ", " then "]

    private static let maxWordsPerPoint = 26
    private static let minWordsPerPart = 3

    /// Trims a point down to what belongs on a line: no leading filler, no
    /// trailing punctuation, and a capital at the front.
    ///
    /// Returns nil for anything left too thin to be worth a bullet — an "um"
    /// on its own, or a stray word between two thoughts.
    private static func tidy(_ text: String) -> String? {
        var piece = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Repeatedly, because dictation stacks them: "so um basically…".
        var strippedSomething = true
        while strippedSomething {
            strippedSomething = false
            for filler in leadingFiller {
                guard piece.lowercased().hasPrefix(filler + " ") else { continue }
                piece = String(piece.dropFirst(filler.count + 1))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                strippedSomething = true
            }
            while let first = piece.first, first == "," || first == "." {
                piece = String(piece.dropFirst())
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                strippedSomething = true
            }
        }

        piece = piece.trimmingCharacters(in: CharacterSet(charactersIn: " .,;:"))
        guard piece.split(separator: " ").count >= 2 else { return nil }
        return piece.prefix(1).uppercased() + piece.dropFirst()
    }

    private static let leadingFiller = [
        "um", "uh", "er", "so", "and", "but", "like", "okay", "ok", "well",
        "you know", "i mean", "basically", "actually", "right"
    ]

    private static func comparisonKey(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber || $0 == " " }
            .trimmingCharacters(in: .whitespaces)
    }

    /// Content words only — the ones worth scoring a sentence by.
    private static func terms(in sentence: String) -> [String] {
        sentence.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count > 2 && !stopWords.contains($0) }
    }

    private static let stopWords: Set<String> = [
        "the", "and", "for", "are", "but", "not", "you", "all", "any", "can",
        "her", "was", "one", "our", "out", "day", "get", "has", "him", "his",
        "how", "its", "new", "now", "old", "see", "two", "way", "who", "did",
        "yes", "his", "been", "have", "this", "that", "with", "they", "from",
        "what", "were", "when", "your", "said", "there", "their", "would",
        "about", "which", "will", "into", "just", "them", "then", "than",
        "some", "more", "over", "also", "like", "want", "need", "really",
        "going", "gonna", "kind", "sort", "thing", "things", "stuff", "very",
        "much", "make", "made", "take", "took", "come", "came", "know"
    ]
}
