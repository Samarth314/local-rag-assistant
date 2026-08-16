import Foundation

/// Who said which part of a note.
///
/// ## What this is, and firmly is not
///
/// Not speaker recognition. It cannot tell you *who* anyone is, cannot tell
/// two guests apart, and does not build a voice profile of anybody. It answers
/// exactly one question — **is this the person holding the phone, or someone
/// else in the room** — which is the question a note taken in a meeting
/// actually needs, and the only one that is answerable cheaply and honestly.
///
/// ## How, and why this feature is free
///
/// Proximity, not timbre. The phone sits with its owner, so their voice
/// reaches the microphone several decibels louder than anyone across a table,
/// and that gap survives everything real diarisation needs a neural embedding
/// to handle. So the whole method is: measure loudness per word from audio the
/// app already captured, cluster it in one dimension, and see whether the two
/// clusters are actually separate.
///
/// The cost is one pass of squares over the samples — no model, no FFT, no
/// network, nothing on the recording path. A three-minute note is a few
/// million multiply-adds, which is a handful of milliseconds once, after the
/// user has already stopped talking.
///
/// ## When it declines to answer
///
/// Most notes are one person talking, and a solo note labelled with two
/// speakers is worse than one labelled with none. So `turns` returns nil
/// unless the evidence is there: two clusters separated by a real margin, each
/// holding a meaningful share of the words. Silence about a thing you cannot
/// establish beats a confident guess.
enum SpeakerSplit {

    enum Speaker: String, Codable, Hashable {
        /// The phone's owner - the loud, close cluster.
        case you
        /// Anybody else in the room. Deliberately not numbered: distance tells
        /// you near from far, and nothing tells you one guest from another.
        case other

        var label: String {
            switch self {
            case .you:   return "You"
            case .other: return "Someone else"
            }
        }
    }

    struct Turn: Codable, Hashable {
        var speaker: Speaker
        var text: String
    }

    /// Minimum gap between the two clusters' mean loudness, in decibels.
    ///
    /// Six is about the difference between a phone on the table in front of
    /// you and one across it. Below that the "two speakers" are far more
    /// likely to be one person leaning in and out.
    static let minimumSeparation: Double = 6

    /// The quieter side must be at least this share of the words, so one
    /// mumbled aside cannot invent a second speaker.
    static let minimumShare: Double = 0.15

    /// Splits a transcript into turns, or nil when there is no good reason to
    /// believe more than one person spoke.
    ///
    /// - Parameters:
    ///   - words: recognised words with their place in the recording.
    ///   - samples: the recording, 16 kHz mono.
    static func turns(words: [SpeechDictation.TimedWord],
                      samples: [Float],
                      sampleRate: Double = 16_000) -> [Turn]? {
        guard words.count >= 6, !samples.isEmpty else { return nil }

        let levels = words.map { loudness(of: $0, in: samples, sampleRate: sampleRate) }
        // Words that landed on silence carry no evidence either way; scoring
        // them would drag every cluster toward the noise floor.
        let audible = levels.enumerated().filter { $0.element > -60 }
        guard audible.count >= 6 else { return nil }

        guard let split = cluster(audible.map(\.element)) else { return nil }

        let loudCentre = max(split.low, split.high)
        var turns: [Turn] = []
        for (index, word) in words.enumerated() {
            let level = levels[index]
            // An inaudible word joins whoever was last speaking rather than
            // starting a turn of its own.
            let speaker: Speaker
            if level <= -60, let last = turns.last {
                speaker = last.speaker
            } else {
                let nearHigh = abs(level - split.high) <= abs(level - split.low)
                let isLoudCluster = (nearHigh && split.high == loudCentre)
                    || (!nearHigh && split.low == loudCentre)
                speaker = isLoudCluster ? .you : .other
            }

            if var last = turns.last, last.speaker == speaker {
                last.text += " " + word.text
                turns[turns.count - 1] = last
            } else {
                turns.append(Turn(speaker: speaker, text: word.text))
            }
        }
        // A "conversation" that came out as one turn is one speaker, whatever
        // the clustering said.
        return turns.count > 1 ? turns : nil
    }

    // MARK: - Measurement

    /// Mean power over a word's span, in dBFS.
    static func loudness(of word: SpeechDictation.TimedWord,
                         in samples: [Float], sampleRate: Double) -> Double {
        let start = Int(word.start * sampleRate)
        let end = Int((word.start + word.duration) * sampleRate)
        let lower = max(0, min(start, samples.count))
        let upper = max(lower, min(end, samples.count))
        guard upper > lower else { return -120 }

        var sum = 0.0
        for index in lower..<upper {
            let value = Double(samples[index])
            sum += value * value
        }
        let rms = (sum / Double(upper - lower)).squareRoot()
        guard rms > 0 else { return -120 }
        return 20 * log10(rms)
    }

    // MARK: - Clustering

    struct Split: Equatable {
        let low: Double
        let high: Double
    }

    /// One-dimensional 2-means, then a hard look at whether it found anything.
    ///
    /// Seeded at the extremes rather than randomly, which for one dimension is
    /// both the standard choice and what makes this deterministic — the same
    /// note must never split two ways on two runs.
    static func cluster(_ values: [Double]) -> Split? {
        guard let min = values.min(), let max = values.max(), values.count >= 6 else {
            return nil
        }
        guard max - min >= minimumSeparation else { return nil }

        var low = min
        var high = max
        for _ in 0..<12 {
            var lowSide: [Double] = []
            var highSide: [Double] = []
            for value in values {
                if abs(value - low) <= abs(value - high) {
                    lowSide.append(value)
                } else {
                    highSide.append(value)
                }
            }
            guard !lowSide.isEmpty, !highSide.isEmpty else { return nil }
            let nextLow = lowSide.reduce(0, +) / Double(lowSide.count)
            let nextHigh = highSide.reduce(0, +) / Double(highSide.count)
            if nextLow == low && nextHigh == high { break }
            low = nextLow
            high = nextHigh
        }

        guard high - low >= minimumSeparation else { return nil }

        // Both sides have to be populated enough to be a speaker rather than
        // an outlier.
        let quiet = values.filter { abs($0 - low) <= abs($0 - high) }.count
        let share = Double(Swift.min(quiet, values.count - quiet)) / Double(values.count)
        guard share >= minimumShare else { return nil }

        return Split(low: low, high: high)
    }
}
