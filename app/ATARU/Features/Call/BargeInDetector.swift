import Foundation

/// Decides, from microphone levels alone, whether somebody is talking over an
/// answer - or whether the loudspeaker is feeding the answer back into the
/// microphone.
///
/// ## Why a fixed threshold was never going to work
///
/// The old rule was one number: level above `BargeInTuning.level` and the
/// answer stops. That number was chosen in a Simulator, where the "speaker"
/// is a Mac and there is no room. On a handset on speakerphone the answer
/// comes back into the microphone at a level that depends on the room, the
/// volume, whether the phone is face-up on a table, and which way it is
/// pointing. There is no single constant that is above the echo in a kitchen
/// and below a quiet voice in a car, so tuning the constant means collecting
/// data from the actual phone in the actual rooms - and until somebody does
/// that, every call is running on a guess.
///
/// This type removes the dependency on that guess. Rather than compare the
/// level to a constant, it MEASURES the echo and compares the level to what it
/// measured:
///
///  1. **Calibration.** For the first `calibrationMs` after playback starts,
///     it only listens. Nobody has begun talking over a sentence that has
///     barely started, so whatever the microphone reports in that window is
///     echo plus room, by construction. The mean of it becomes the floor.
///  2. **A tracked floor.** For the rest of the answer, every sample that is
///     not a barge-in candidate updates the floor as an EMA. A room that gets
///     louder, a volume the caller turns up, a phone that gets put down on a
///     hard table - the floor follows all of it.
///  3. **A relative threshold.** A candidate must clear
///     `max(tuning.level, floor + tuning.margin)`. The configured level stays
///     as an absolute lower bound, so a silent room cannot make a cough into
///     an interruption.
///  4. **A rising edge.** The level must have been down AT the floor recently
///     before the burst began. Steady echo - any steady anything - therefore
///     cannot trigger, however loud it is: it has no edge, and the floor
///     climbs to meet it.
///  5. **Sustain.** Two consecutive qualifying samples minimum, whatever the
///     server says, plus whatever `tuning.sustainedMs` asks for on top. One
///     sample is a door, a click, a plosive on the case.
///
/// The result is that echo cannot trigger a barge-in by being loud. It could
/// only do it by being loud SUDDENLY, after being quiet, and staying loud -
/// which is what speech is, and which is the residual the hardware echo
/// canceller (`SpeechDictation.usesVoiceProcessing`) exists to remove.
///
/// ## Pure on purpose
///
/// Levels in, verdict out, clock passed as an argument. Same reasoning as
/// `EndOfTurn`: the alternative is a rule that can only be checked by holding
/// a phone in a room, which is exactly the data nobody has.
final class BargeInDetector {

    /// How long after playback starts is spent measuring rather than deciding.
    ///
    /// 400ms is about two syllables of TTS - long enough for the echo path to
    /// be represented in the average, short enough that a caller who cuts in
    /// early is only slightly late being heard. The post-TTS cooldown, when
    /// the server sets one, extends this.
    static let defaultCalibrationMs = 400

    /// How stale a "the level was down at the floor" observation may be and
    /// still count as the edge this burst rose from.
    static let defaultRisingWindowMs = 2_500

    /// A burst above the threshold that outlasts this is not somebody talking
    /// over a sentence; it is the new steady state. The floor absorbs it and
    /// the burst is abandoned, so the detector keeps working for the rest of
    /// the answer instead of sitting latched.
    static let defaultBurstCeilingMs = 4_000

    /// EMA weight for a new sample. 0.25 at the monitor's 120ms cadence means
    /// the floor is most of the way to a new steady level inside half a
    /// second - fast enough to follow a room, slow enough that it does not
    /// chase a single loud syllable.
    static let defaultSmoothing = 0.25

    /// The compiled minimum sustain, in samples, and it is deliberately not a
    /// duration: the server's `sustained_ms` defaults to 0 (the behaviour
    /// this app shipped with, acting on the first sample that passed), and a
    /// single sample is exactly what a click looks like.
    static let minimumSamples = 2

    let tuning: BargeInTuning
    private let calibrationMs: Int
    private let risingWindowMs: Int
    private let burstCeilingMs: Int
    private let smoothing: Double
    private let minimumSamples: Int

    /// The measured echo-plus-room level, 0...1. Reported with a barge-in so
    /// the server journal can tell a trigger over a quiet room from one over a
    /// room that was already loud.
    private(set) var floor: Double = 0

    /// How far above the floor a level has to be. Straight off the tuning;
    /// exposed so the caller can journal what the decision was made against.
    var margin: Double { tuning.margin }

    /// What a level has to clear right now.
    var threshold: Double { max(tuning.level, floor + tuning.margin) }

    /// When the window stops measuring and starts deciding.
    private var windowOpenMs: Int { max(calibrationMs, tuning.cooldownMs) }

    private var calibrationSum: Double = 0
    private var calibrationCount = 0
    private var calibrated = false
    private var lastMs = Int.min
    /// The most recent sample that sat down at the floor, and the reason
    /// steady echo cannot fire. Only counted once the window is open, so a
    /// level that is loud from the first sample to the last never acquires an
    /// edge to rise from.
    private var quietAtMs: Int?
    private var burstStartMs: Int?
    private var burstSamples = 0

    init(tuning: BargeInTuning,
         calibrationMs: Int = BargeInDetector.defaultCalibrationMs,
         risingWindowMs: Int = BargeInDetector.defaultRisingWindowMs,
         burstCeilingMs: Int = BargeInDetector.defaultBurstCeilingMs,
         smoothing: Double = BargeInDetector.defaultSmoothing,
         minimumSamples: Int = BargeInDetector.minimumSamples) {
        self.tuning = tuning
        self.calibrationMs = max(0, calibrationMs)
        self.risingWindowMs = max(0, risingWindowMs)
        self.burstCeilingMs = max(0, burstCeilingMs)
        self.smoothing = min(max(smoothing, 0.01), 1)
        self.minimumSamples = max(1, minimumSamples)
    }

    /// One microphone reading.
    ///
    /// - Parameters:
    ///   - level: peak amplitude 0...1, as `SpeechDictation.level` reports it.
    ///   - ms: milliseconds since playback started. Monotonic; a sample that
    ///     goes backwards is ignored rather than trusted.
    /// - Returns: whether the LEVEL says the caller is cutting in. The text
    ///   backstop (`BargeIn.shouldInterrupt`) is a separate gate and both are
    ///   required - see `CallSessionModel.beginBargeIn`.
    ///
    /// True for every sample of a qualifying burst, not just its first: the
    /// caller re-checks the word gate on each one, and a burst whose words
    /// have not arrived yet must still be able to fire when they do.
    @discardableResult
    func feed(level: Float, at ms: Int) -> Bool {
        guard ms >= lastMs else { return false }
        lastMs = ms
        let value = Double(min(max(level, 0), 1))

        // 1. MEASURING. Nobody has spoken yet, by construction: this is the
        //    first fraction of a second of a sentence the caller has not
        //    heard the end of. Whatever arrives here is the echo path.
        if ms < calibrationMs {
            calibrationSum += value
            calibrationCount += 1
            floor = calibrationSum / Double(calibrationCount)
            resetBurst()
            return false
        }
        if !calibrated {
            calibrated = true
            // A window that never got a sample - a monitor that started late,
            // a muted stretch - takes the first reading it does get rather
            // than deciding against a floor of zero.
            if calibrationCount == 0 { floor = value }
        }

        // 2. BELOW THE BAR. This is the room talking, so it teaches the floor.
        guard value > threshold else {
            floor += smoothing * (value - floor)
            // Down at the floor: the edge a later burst is allowed to rise
            // from. Half the margin rather than the floor exactly, because
            // the floor is an average and half the samples sit above it.
            if ms >= windowOpenMs, value <= floor + tuning.margin / 2 {
                quietAtMs = ms
            }
            resetBurst()
            return false
        }

        // 3. THE COOLDOWN. The loudest part of an answer is its first
        //    syllable and it is the most likely to get past the echo
        //    canceller. Nothing that begins in here is a burst at all - not
        //    "a burst that fires late", which would just move the false
        //    trigger to the far edge of the cooldown.
        guard ms >= windowOpenMs else {
            resetBurst()
            return false
        }

        let began = burstStartMs ?? ms
        burstStartMs = began
        burstSamples += 1

        // 4. A burst this long is not an interruption, it is the new normal -
        //    the volume went up, the phone was set down on a table. Let the
        //    floor have it and start again, rather than staying latched high
        //    for the rest of the answer.
        if ms - began >= burstCeilingMs {
            floor += smoothing * (value - floor)
            resetBurst()
            return false
        }

        // 5. THE RISING EDGE, and the whole reason steady echo is structurally
        //    unable to fire: there has to have been a moment, recently and
        //    after the window opened, when the microphone was down at the
        //    floor. Continuous anything has no such moment.
        guard let quiet = quietAtMs, quiet <= began,
              began - quiet <= risingWindowMs else { return false }

        // 6. SUSTAIN. The compiled two-sample minimum first, then whatever the
        //    server asked for on top of it.
        guard burstSamples >= minimumSamples,
              ms - began >= tuning.sustainedMs else { return false }
        return true
    }

    private func resetBurst() {
        burstStartMs = nil
        burstSamples = 0
    }
}
