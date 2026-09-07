import XCTest
@testable import ATARU

/// Synthetic microphone traces against `BargeInDetector`.
///
/// The point of the type is that the barge-in decision stops depending on a
/// constant somebody guessed against a room nobody measured - so the point of
/// these is that the decision can be checked without a room at all. Every
/// trace below is a level sequence at the monitor's real 120ms cadence, and
/// the numbers are the ones the failure modes actually look like: echo in the
/// 0.10-0.20 band, speech at 0.5-0.6, a click at full scale for one sample.
final class BargeInDetectorTests: XCTestCase {

    /// The monitor's poll interval. Traces are fed at exactly this cadence
    /// because a sample count is what the compiled sustain minimum is in.
    private let step = 120

    private func tuning(level: Double = 0.12, margin: Double = 0.10,
                        sustainedMs: Int = 0, cooldownMs: Int = 0) -> BargeInTuning {
        BargeInTuning(level: level, margin: margin,
                      sustainedMs: sustainedMs, cooldownMs: cooldownMs)
    }

    /// Feeds a level-per-sample trace and reports how many times the verdict
    /// went from false to true - one interruption per rising run, which is
    /// what "fires once" means for a burst that spans several samples.
    @discardableResult
    private func run(_ levels: [Float], through detector: BargeInDetector,
                     from startMs: Int = 0) -> (fires: Int, firstMs: Int?) {
        var fires = 0
        var firstMs: Int?
        var previous = false
        for (index, level) in levels.enumerated() {
            let ms = startMs + index * step
            let verdict = detector.feed(level: level, at: ms)
            if verdict, !previous {
                fires += 1
                if firstMs == nil { firstMs = ms }
            }
            previous = verdict
        }
        return (fires, firstMs)
    }

    // MARK: - (a) steady echo

    /// The failure this whole redesign is about: the loudspeaker feeding the
    /// answer back into the microphone, continuously, at a level well over the
    /// configured 0.12. The old predicate stopped the answer on the first
    /// sample of this. The floor climbs to meet it instead.
    func testSteadyEchoNeverFires() {
        let detector = BargeInDetector(tuning: tuning())
        // Three seconds of 0.10/0.20 alternation - loud enough that every
        // other sample clears the absolute threshold on its own.
        let levels = (0..<25).map { Float($0.isMultiple(of: 2) ? 0.10 : 0.20) }
        XCTAssertEqual(run(levels, through: detector).fires, 0)
        // And the floor is where the echo is, not at zero: this is the number
        // that goes in the journal beside a trigger.
        XCTAssertEqual(detector.floor, 0.15, accuracy: 0.03)
    }

    /// Same shape, louder room. Nothing about the absolute numbers matters -
    /// only that they are steady.
    func testLoudSteadyEchoNeverFiresEither() {
        let detector = BargeInDetector(tuning: tuning())
        let levels = (0..<25).map { Float($0.isMultiple(of: 2) ? 0.30 : 0.40) }
        XCTAssertEqual(run(levels, through: detector).fires, 0)
    }

    // MARK: - (b) echo, then somebody talks

    func testASpeechBurstOverEchoFiresOnce() {
        let detector = BargeInDetector(tuning: tuning())
        // 1.8s of echo at 0.15, then 400ms rising 0.15 -> 0.60.
        var levels = [Float](repeating: 0.15, count: 15)
        levels += [0.15, 0.30, 0.45, 0.60]
        let result = run(levels, through: detector)
        XCTAssertEqual(result.fires, 1)
        // And not on the first sample over the bar: the compiled two-sample
        // minimum is what a click is rejected by.
        XCTAssertNotNil(result.firstMs)
    }

    /// The burst has to hold. One sample over the bar is not an interruption
    /// even when the rest of the trace is textbook.
    func testASingleSampleOfSpeechIsNotEnough() {
        let detector = BargeInDetector(tuning: tuning())
        var levels = [Float](repeating: 0.15, count: 15)
        levels += [0.60, 0.15, 0.15, 0.15]
        XCTAssertEqual(run(levels, through: detector).fires, 0)
    }

    /// Two separate interruptions in one answer are two fires, not one: the
    /// burst state resets when the level comes back down to the floor.
    func testASecondBurstCanFireAgain() {
        let detector = BargeInDetector(tuning: tuning())
        var levels = [Float](repeating: 0.15, count: 10)
        levels += [0.55, 0.60, 0.55]
        levels += [Float](repeating: 0.15, count: 10)
        levels += [0.55, 0.60, 0.55]
        XCTAssertEqual(run(levels, through: detector).fires, 2)
    }

    // MARK: - (c) the cooldown

    /// The server can ask for a window at the start of an answer where nothing
    /// counts - the leading syllable of TTS is its loudest part. Speech inside
    /// it is not a barge-in, and neither is a burst that merely STARTED inside
    /// it: a burst has to begin after the window opens, or a cooldown would
    /// just move the false trigger to its far edge.
    func testSpeechInsideTheCooldownDoesNotFire() {
        let detector = BargeInDetector(tuning: tuning(cooldownMs: 1_000))
        // 400ms of echo, then loud speech for the rest of the cooldown.
        var levels = [Float](repeating: 0.10, count: 4)
        levels += [Float](repeating: 0.60, count: 5)   // 480ms .. 960ms
        XCTAssertEqual(run(levels, through: detector).fires, 0)
    }

    /// And the same trace with no cooldown configured still cannot fire inside
    /// the calibration window, because that window is where the floor comes
    /// from and there is nothing to compare against yet.
    func testNothingFiresDuringCalibration() {
        let detector = BargeInDetector(tuning: tuning())
        let levels = [Float](repeating: 0.90, count: 4)   // 0 .. 360ms
        XCTAssertEqual(run(levels, through: detector).fires, 0)
    }

    // MARK: - (d) a click

    func testASingleSampleSpikeDoesNotFire() {
        let detector = BargeInDetector(tuning: tuning())
        var levels = [Float](repeating: 0.12, count: 10)
        levels += [1.0]                                    // a door, a table tap
        levels += [Float](repeating: 0.12, count: 10)
        XCTAssertEqual(run(levels, through: detector).fires, 0)
    }

    /// Several isolated clicks are still no interruption - the burst counter
    /// resets between them rather than accumulating across the answer.
    func testRepeatedIsolatedClicksDoNotAddUp() {
        let detector = BargeInDetector(tuning: tuning())
        var levels: [Float] = []
        for _ in 0..<6 { levels += [0.12, 0.12, 0.95] }
        XCTAssertEqual(run(levels, through: detector).fires, 0)
    }

    // MARK: - (e) floor drift

    /// The room gets louder over the course of an answer - the volume goes up,
    /// the phone is set down on a hard surface, the caller walks toward a
    /// wall. The echo triples, and it still cannot fire, because it never
    /// stops being steady.
    func testAnEchoFloorThatDriftsUpwardNeverFires() {
        let detector = BargeInDetector(tuning: tuning())
        // 0.10 -> 0.30 over three seconds.
        let levels = (0..<25).map { Float(0.10 + 0.008 * Double($0)) }
        XCTAssertEqual(run(levels, through: detector).fires, 0)
        // The floor followed it, which is why nothing fired.
        XCTAssertGreaterThan(detector.floor, 0.20)
    }

    /// The drifted floor is still a floor: speech over the LOUD end of that
    /// drift is heard, so following the room does not mean going deaf.
    func testSpeechOverADriftedFloorStillFires() {
        let detector = BargeInDetector(tuning: tuning())
        let drift = (0..<25).map { Float(0.10 + 0.008 * Double($0)) }
        run(drift, through: detector)
        let after = drift.count * step
        XCTAssertEqual(run([0.30, 0.65, 0.70, 0.65], through: detector,
                           from: after).fires, 1)
    }

    // MARK: - the rules themselves

    /// A quiet calibration window and then a level that is over the bar from
    /// the first sample after it to the last: no rising edge is ever
    /// available, so nothing can fire however far over the bar it sits. This
    /// is the structural guarantee the whole type exists for, and it is what
    /// covers an answer whose audio simply ramps up late.
    func testAJumpToASteadyLoudLevelNeverFires() {
        let detector = BargeInDetector(tuning: tuning())
        var levels = [Float](repeating: 0.05, count: 4)     // the calibration window
        levels += [Float](repeating: 0.55, count: 30)       // and then, loudly, forever
        XCTAssertEqual(run(levels, through: detector).fires, 0)
    }

    /// The configured level stays an absolute lower bound: a silent room
    /// measures a floor near zero, and a quiet rustle must not become an
    /// interruption just because it is far above nothing.
    func testTheConfiguredLevelIsStillAFloorInASilentRoom() {
        let detector = BargeInDetector(tuning: tuning())
        var levels = [Float](repeating: 0.005, count: 10)
        levels += [0.09, 0.10, 0.09]        // over the measured floor, under 0.12
        XCTAssertEqual(run(levels, through: detector).fires, 0)
    }

    /// The server's sustain is applied ON TOP of the compiled two-sample
    /// minimum, not instead of it.
    func testTheServersSustainIsHonoured() {
        let long = BargeInDetector(tuning: tuning(sustainedMs: 600))
        var levels = [Float](repeating: 0.15, count: 10)
        levels += [0.60, 0.60, 0.60]        // 360ms of speech, short of 600
        XCTAssertEqual(run(levels, through: long).fires, 0)

        let same = BargeInDetector(tuning: tuning(sustainedMs: 600))
        var longer = [Float](repeating: 0.15, count: 10)
        longer += [Float](repeating: 0.60, count: 7)
        XCTAssertEqual(run(longer, through: same).fires, 1)
    }

    /// A sample whose clock went backwards is ignored rather than trusted -
    /// the same defensive shape `EndOfTurn` has about its own clock.
    func testABackwardsSampleIsIgnored() {
        let detector = BargeInDetector(tuning: tuning())
        XCTAssertFalse(detector.feed(level: 0.1, at: 1_000))
        XCTAssertFalse(detector.feed(level: 0.9, at: 500))
    }

    /// What gets journalled: the floor the decision was made against and the
    /// margin it had to clear. Both are readable before anything fires.
    func testTheFloorAndMarginAreReportable() {
        let detector = BargeInDetector(tuning: tuning(margin: 0.2))
        run([Float](repeating: 0.25, count: 4), through: detector)
        XCTAssertEqual(detector.floor, 0.25, accuracy: 0.001)
        XCTAssertEqual(detector.margin, 0.2, accuracy: 0.001)
        XCTAssertEqual(detector.threshold, 0.45, accuracy: 0.001)
    }
}

/// The fourth knob, and the fail-closed rules around it.
final class BargeInMarginTuningTests: XCTestCase {

    func testAServerThatSaysNothingLeavesTheCompiledMargin() {
        let tuning = BargeInTuning(level: nil, margin: nil,
                                   sustainedMs: nil, cooldownMs: nil)
        XCTAssertEqual(tuning.margin, CallSessionModel.bargeMargin)
        XCTAssertEqual(tuning, .default)
    }

    /// A margin of zero IS a tuning somebody could mean - "trust the absolute
    /// level" - so unlike a level of zero it is accepted rather than refused.
    func testAZeroMarginIsAccepted() {
        XCTAssertEqual(BargeInTuning(level: nil, margin: 0,
                                     sustainedMs: nil, cooldownMs: nil).margin, 0)
    }

    func testNonsenseMarginsFallBack() {
        for value in [-0.5, 1.0, 4.0] {
            XCTAssertEqual(BargeInTuning(level: nil, margin: value,
                                         sustainedMs: nil, cooldownMs: nil).margin,
                           CallSessionModel.bargeMargin)
        }
    }

    /// The whole point of a zero margin, stated as behaviour: the threshold
    /// collapses back onto the configured level, and steady echo above it is
    /// then held off by the rising edge alone rather than by the floor.
    func testAZeroMarginStillCannotBeFiredBySteadyEcho() {
        let detector = BargeInDetector(
            tuning: BargeInTuning(level: 0.12, margin: 0,
                                  sustainedMs: nil, cooldownMs: nil))
        var fired = false
        for index in 0..<30 {
            // Quiet through the calibration window, then loud and steady.
            let level: Float = index < 4 ? 0.05 : 0.50
            if detector.feed(level: level, at: index * 120) { fired = true }
        }
        XCTAssertFalse(fired)
    }
}

/// The journal fields that ride out on the next question.
final class BargeInReportTests: XCTestCase {

    func testTheReportCarriesTheFloorAndMarginItWasMeasuredAgainst() {
        let report = STTConfidence()
            .reportingBargeIn(level: 0.42, afterMs: 1_800, floor: 0.18, margin: 0.10)
        let object = report.jsonObject
        XCTAssertEqual(object["barge_in"] as? Bool, true)
        XCTAssertEqual(object["barge_level"] as? Double, 0.42)
        XCTAssertEqual(object["barge_after_ms"] as? Int, 1_800)
        XCTAssertEqual(object["barge_floor"] as? Double, 0.18)
        XCTAssertEqual(object["barge_margin"] as? Double, 0.10)
    }

    /// Numbers about audio and nothing else. A field that could hold what was
    /// heard is the one thing this report must never grow.
    func testTheReportCarriesNoText() {
        let object = STTConfidence()
            .reportingBargeIn(level: 0.42, afterMs: 1_800, floor: 0.18, margin: 0.10)
            .jsonObject
        XCTAssertTrue(object.values.allSatisfy { !($0 is String) })
    }

    /// A turn that was not interrupted says nothing at all about barge-in.
    func testAnUninterruptedTurnReportsNothing() {
        let object = STTConfidence(lowConfidence: true).jsonObject
        XCTAssertNil(object["barge_floor"])
        XCTAssertNil(object["barge_margin"])
        XCTAssertNil(object["barge_in"])
    }
}

/// Local routine reminders and whose day boundary they use.
@MainActor
final class RoutineReminderTimeZoneTests: XCTestCase {

    private func routine(tz: String) -> DailyRoutine {
        DailyRoutine(date: "2026-09-07", tz: tz,
                     items: [RoutineItem(id: "white-pine", label: "White pine",
                                         detail: "", done: false, doneAt: nil)],
                     reminderTimes: ["18:00"])
    }

    /// The server names a zone: that is the one the trigger fires in, whatever
    /// the phone's own clock says.
    func testTheServersZoneIsUsedWhenItNamesOne() {
        var phone = Calendar(identifier: .gregorian)
        phone.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let calendar = RoutineReminders.calendar(for: routine(tz: "America/Los_Angeles"),
                                                 default: phone)
        XCTAssertEqual(calendar.timeZone.identifier, "America/Los_Angeles")
    }

    /// And the hour means the hour THERE - the two calendars disagree about
    /// what instant "18:00 today" is, which is the entire bug.
    func testTheFiringInstantFollowsTheServersZone() {
        var phone = Calendar(identifier: .gregorian)
        phone.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let server = RoutineReminders.calendar(for: routine(tz: "America/Los_Angeles"),
                                               default: phone)
        let now = Date(timeIntervalSince1970: 1_757_260_800)
        let here = phone.date(bySettingHour: 18, minute: 0, second: 0, of: now)
        let there = server.date(bySettingHour: 18, minute: 0, second: 0, of: now)
        XCTAssertNotNil(here)
        XCTAssertNotNil(there)
        XCTAssertNotEqual(here, there)
    }

    /// An empty or unrecognised identifier leaves the phone's own calendar in
    /// place, which is what this always did - a fallback reminder is better
    /// than none.
    func testAnUnknownZoneFallsBackToThePhone() {
        var phone = Calendar(identifier: .gregorian)
        phone.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        for value in ["", "Mars/Olympus_Mons", "PST8PDT7"] {
            XCTAssertEqual(
                RoutineReminders.calendar(for: routine(tz: value), default: phone).timeZone,
                phone.timeZone)
        }
    }
}
