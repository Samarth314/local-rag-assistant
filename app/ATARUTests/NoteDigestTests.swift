import XCTest
@testable import ATARU

/// The whole of the notes feature that is not drawing or microphone plumbing.
///
/// Worth testing directly because the input is genuinely nasty: dictation
/// arrives unpunctuated, repeats itself when the speaker revises, and stacks
/// filler at the front of every other clause. A summary is a judgement call and
/// hard to assert, but the properties below are not — and they are the ones
/// that decide whether a note is readable.
final class NoteDigestTests: XCTestCase {

    // MARK: - Points

    func testARunOnIsBrokenIntoSeparatePoints() {
        // No sentence punctuation at all, which is the normal case.
        let digest = NoteDigest.make(from: """
        call the landlord about the boiler and then book the dentist for \
        thursday also pick up the prescription before six
        """)

        XCTAssertGreaterThanOrEqual(digest.bullets.count, 3,
                                    "a run-on should not land as one bullet")
        XCTAssertTrue(digest.bullets.contains { $0.lowercased().contains("landlord") })
        XCTAssertTrue(digest.bullets.contains { $0.lowercased().contains("dentist") })
        XCTAssertTrue(digest.bullets.contains { $0.lowercased().contains("prescription") })
    }

    func testNoPointIsLongerThanAPersonWouldRead() {
        let digest = NoteDigest.make(from: """
        so the plan for the quarter is to finish the indexing rebuild and then \
        migrate the vault onto the new disk and then get the backups verified \
        and also we need to rewrite the ingest docs but that can wait
        """)

        for bullet in digest.bullets {
            XCTAssertLessThanOrEqual(bullet.split(separator: " ").count, 30,
                                     "“\(bullet)” is a paragraph, not a bullet")
        }
    }

    func testLeadingFillerIsStripped() {
        let digest = NoteDigest.make(from: """
        um so basically the deploy is broken. uh you know we should roll it back. \
        okay and then tell the team.
        """)

        for bullet in digest.bullets {
            let first = bullet.split(separator: " ").first?.lowercased() ?? ""
            XCTAssertFalse(["um", "uh", "so", "okay", "basically", "and"].contains(first),
                           "“\(bullet)” still opens with filler")
        }
    }

    func testEveryPointStartsWithACapitalAndCarriesNoTrailingStop() {
        let digest = NoteDigest.make(from: """
        check the tyre pressure. book the mot. renew the insurance before august.
        """)

        for bullet in digest.bullets {
            XCTAssertEqual(bullet.first, bullet.first?.uppercased().first)
            XCTAssertFalse(bullet.hasSuffix("."), "“\(bullet)” keeps a trailing stop")
        }
    }

    /// Dictation repeats itself when the speaker corrects mid-flow.
    func testARepeatedPointAppearsOnce() {
        let digest = NoteDigest.make(from: """
        Email Arya about the launcher. Email Arya about the launcher. \
        Then update the changelog.
        """)

        let launcherPoints = digest.bullets.filter { $0.lowercased().contains("launcher") }
        XCTAssertEqual(launcherPoints.count, 1)
    }

    func testAStrayWordIsNotAPoint() {
        let digest = NoteDigest.make(from: "Buy milk. Um. Also call the bank.")
        XCTAssertFalse(digest.bullets.contains { $0.split(separator: " ").count < 2 })
    }

    // MARK: - Summary

    func testAShortNoteIsItsOwnSummaryRatherThanHalfOfItself() {
        // Extracting "the best" of two sentences throws away half a note that
        // was already short enough to read.
        let digest = NoteDigest.make(from: "Book the flight. Pay the deposit.")
        XCTAssertEqual(digest.bullets.count, 2)
        for bullet in digest.bullets {
            XCTAssertTrue(digest.summary.contains(bullet),
                          "a two-point note dropped “\(bullet)” from its summary")
        }
    }

    func testALongNoteGetsAShorterSummaryThanItself() {
        let transcript = """
        The vault migration is the main thing this week. We need to move the \
        vault onto the new disk. The vault has about four hundred gigabytes on \
        it. Backups have to be verified after the vault move. I should tell \
        Arya once the vault is migrated. The dentist is on thursday.
        """
        let digest = NoteDigest.make(from: transcript)

        XCTAssertGreaterThan(digest.bullets.count, 3)
        XCTAssertLessThan(digest.summary.count, transcript.count / 2,
                          "the summary is nearly the whole note")
        // Extractive, so every summary sentence must be something that was
        // actually said - the one property that separates this from a model
        // writing new prose, which is exactly what this feature must not do.
        XCTAssertTrue(digest.summary.lowercased().contains("vault"),
                      "the summary missed what the note was mostly about")
    }

    func testTheSummaryKeepsTheOrderThingsWereSaidIn() {
        let digest = NoteDigest.make(from: """
        First we ship the launcher. Then we ship the notes screen. Then we ship \
        the settings rewrite. The launcher is nearly done. The notes screen is \
        not started. The settings rewrite is not scheduled.
        """)

        let points = NoteDigest.points(in: """
        First we ship the launcher. Then we ship the notes screen. Then we ship \
        the settings rewrite. The launcher is nearly done. The notes screen is \
        not started. The settings rewrite is not scheduled.
        """)
        let chosen = points.filter { digest.summary.contains($0) }
        let positions = chosen.compactMap { points.firstIndex(of: $0) }
        XCTAssertEqual(positions, positions.sorted(),
                       "the summary reordered what was said")
    }

    // MARK: - Degenerate input

    func testSilenceProducesNothingRatherThanAnEmptyNote() {
        for input in ["", "   ", "\n\n"] {
            let digest = NoteDigest.make(from: input)
            XCTAssertTrue(digest.isEmpty, "“\(input)” produced a note")
        }
    }

    func testAOneWordUtteranceIsNotANote() {
        // The recorder refuses to save an empty digest, so this is what stops
        // a cough becoming a card in the list.
        XCTAssertTrue(NoteDigest.make(from: "um").isEmpty)
    }

    // MARK: - Note

    func testTheTitleIsTheOpeningWordsNotTheSummary() {
        let note = Note(transcript: """
        Remember to renew the parking permit. The permit costs ninety pounds. \
        The permit expires at the end of the month. Parking is impossible \
        without the permit.
        """)

        XCTAssertTrue(note.title.lowercased().hasPrefix("remember"),
                      "the title should read as the note's opening, got “\(note.title)”")
        XCTAssertLessThanOrEqual(note.title.split(separator: " ").count, 8)
    }

    func testANoteRoundTripsThroughJSON() {
        let note = Note(transcript: "Call the bank. Move the standing order.")
        let data = try? JSONEncoder().encode(note)
        XCTAssertNotNil(data)
        let restored = data.flatMap { try? JSONDecoder().decode(Note.self, from: $0) }
        XCTAssertEqual(restored, note)
    }
}
