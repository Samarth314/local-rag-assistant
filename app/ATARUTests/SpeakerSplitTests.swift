import XCTest
@testable import ATARU

/// Diarisation, which is mostly a test of when it refuses to answer.
///
/// The easy half — "loud words and quiet words separate into two groups" — is
/// arithmetic. The half worth defending is the guard: a note of one person
/// talking must come back nil, because a solo note labelled with two speakers
/// is worse than one labelled with none, and a phone leaning in and out is the
/// normal case rather than a second person.
final class SpeakerSplitTests: XCTestCase {

    /// Builds audio where each word's span is a tone at a chosen amplitude.
    private func audio(levels: [Float], wordDuration: Double = 0.4,
                       sampleRate: Double = 16_000)
    -> (words: [SpeechDictation.TimedWord], samples: [Float]) {
        var samples: [Float] = []
        var words: [SpeechDictation.TimedWord] = []
        let perWord = Int(wordDuration * sampleRate)

        for (index, amplitude) in levels.enumerated() {
            words.append(.init(text: "w\(index)",
                               start: Double(index) * wordDuration,
                               duration: wordDuration))
            for sample in 0..<perWord {
                // A tone rather than a constant: RMS of a constant is its own
                // value, which would make the arithmetic trivially right and
                // the test worth nothing.
                let phase = Double(sample) / sampleRate * 220 * 2 * .pi
                samples.append(amplitude * Float(sin(phase)))
            }
        }
        return (words, samples)
    }

    // MARK: - Refusing

    func testOneSpeakerIsNotSplit() {
        // Everyone at one level, give or take the wobble of a real voice.
        let levels: [Float] = [0.30, 0.28, 0.33, 0.29, 0.31, 0.30, 0.32, 0.28]
        let (words, samples) = audio(levels: levels)
        XCTAssertNil(SpeakerSplit.turns(words: words, samples: samples))
    }

    func testLeaningInAndOutIsNotASecondSpeaker() {
        // A ~4 dB drift, under the 6 dB the split insists on.
        let levels: [Float] = [0.30, 0.30, 0.19, 0.19, 0.30, 0.30, 0.19, 0.19]
        let (words, samples) = audio(levels: levels)
        XCTAssertNil(SpeakerSplit.turns(words: words, samples: samples),
                     "a drifting distance should not invent a second speaker")
    }

    func testOneQuietAsideIsNotASecondSpeaker() {
        // Far apart in level, but the quiet side is one word in twelve.
        var levels = [Float](repeating: 0.4, count: 11)
        levels.append(0.02)
        let (words, samples) = audio(levels: levels)
        XCTAssertNil(SpeakerSplit.turns(words: words, samples: samples))
    }

    func testTooFewWordsToJudge() {
        let (words, samples) = audio(levels: [0.4, 0.02, 0.4])
        XCTAssertNil(SpeakerSplit.turns(words: words, samples: samples))
    }

    func testSilenceIsNotASpeaker() {
        let (words, samples) = audio(levels: [Float](repeating: 0, count: 10))
        XCTAssertNil(SpeakerSplit.turns(words: words, samples: samples))
    }

    // MARK: - Splitting

    func testTwoDistancesSplitIntoTwoSpeakers() {
        // ~26 dB apart: a phone in front of you versus across the table.
        let levels: [Float] = [0.40, 0.40, 0.40, 0.02, 0.02, 0.02,
                               0.40, 0.40, 0.02, 0.02]
        let (words, samples) = audio(levels: levels)

        let turns = SpeakerSplit.turns(words: words, samples: samples)
        XCTAssertNotNil(turns)
        XCTAssertEqual(Set(turns?.map(\.speaker) ?? []), [.you, .other])
    }

    func testTheLoudSideIsTheOneHoldingThePhone() {
        let levels: [Float] = [0.40, 0.40, 0.40, 0.02, 0.02, 0.02,
                               0.40, 0.40, 0.02, 0.02]
        let (words, samples) = audio(levels: levels)
        let turns = SpeakerSplit.turns(words: words, samples: samples)

        // Words 0-2 were the loud ones, so the first turn must be "you".
        XCTAssertEqual(turns?.first?.speaker, .you)
        XCTAssertEqual(turns?.first?.text, "w0 w1 w2")
    }

    func testConsecutiveWordsFromOneSpeakerBecomeOneTurn() {
        let levels: [Float] = [0.40, 0.40, 0.40, 0.02, 0.02, 0.02,
                               0.40, 0.40, 0.02, 0.02]
        let (words, samples) = audio(levels: levels)
        let turns = SpeakerSplit.turns(words: words, samples: samples) ?? []

        // Four runs in that pattern, not ten one-word turns.
        XCTAssertEqual(turns.count, 4)
        XCTAssertEqual(turns.map(\.text),
                       ["w0 w1 w2", "w3 w4 w5", "w6 w7", "w8 w9"])
    }

    func testEveryWordSurvivesTheSplit() {
        let levels: [Float] = [0.40, 0.02, 0.40, 0.02, 0.40, 0.02,
                               0.40, 0.02, 0.40, 0.02]
        let (words, samples) = audio(levels: levels)
        let turns = SpeakerSplit.turns(words: words, samples: samples) ?? []

        let spoken = turns.flatMap { $0.text.split(separator: " ").map(String.init) }
        XCTAssertEqual(spoken, words.map(\.text),
                       "diarisation dropped or reordered words")
    }

    // MARK: - Determinism

    func testTheSameNoteAlwaysSplitsTheSameWay() {
        // Seeded at the extremes rather than randomly, so a note cannot come
        // back attributed two different ways on two runs.
        let levels: [Float] = [0.40, 0.40, 0.02, 0.02, 0.40, 0.02, 0.40, 0.02]
        let (words, samples) = audio(levels: levels)

        let first = SpeakerSplit.turns(words: words, samples: samples)
        for _ in 0..<5 {
            XCTAssertEqual(SpeakerSplit.turns(words: words, samples: samples), first)
        }
    }

    // MARK: - Measurement

    func testLoudnessIsMeasuredOverTheWordNotTheWholeRecording() {
        let (words, samples) = audio(levels: [0.5, 0.01])
        let loud = SpeakerSplit.loudness(of: words[0], in: samples, sampleRate: 16_000)
        let quiet = SpeakerSplit.loudness(of: words[1], in: samples, sampleRate: 16_000)

        XCTAssertGreaterThan(loud - quiet, 20)
    }

    func testAWordPastTheEndOfTheAudioDoesNotCrash() {
        let (_, samples) = audio(levels: [0.4])
        let stray = SpeechDictation.TimedWord(text: "x", start: 99, duration: 1)
        XCTAssertEqual(SpeakerSplit.loudness(of: stray, in: samples, sampleRate: 16_000),
                       -120)
    }
}
