import XCTest
@testable import ATARU

/// The openGym document is written by somebody else's app and read back by it
/// within thirty seconds, so the tests that matter here are not about the
/// screens. They are about the four things a client of this document can get
/// wrong silently: dropping a key on the way back up, indexing the week with
/// the wrong calendar, appending a second entry for a day that already has
/// one, and resolving a 409 by re-sending its own copy.
final class GymStateTests: XCTestCase {

    // MARK: - Lossless round trip

    /// A PUT replaces the WHOLE document, so a key this app does not
    /// understand is a key it would delete from Arya's profile.
    func testUnknownKeysSurviveAJSONRoundTrip() throws {
        let json = """
        {"_rev":4,"unit":"kg","routines":[],"somethingNew":{"deep":[1,2.5,true,null]},
         "gifSize":"large","wc":{"steppers":true}}
        """
        let decoded = try JSONDecoder().decode(GymState.self, from: Data(json.utf8))
        let data = try JSONEncoder().encode(decoded)
        let again = try JSONDecoder().decode(GymState.self, from: data)
        XCTAssertEqual(decoded, again)
        XCTAssertEqual(again.raw["somethingNew"]?.objectValue?["deep"]?.arrayValue?.count, 4)
        XCTAssertEqual(again.raw["gifSize"]?.stringValue, "large")
    }

    /// A whole number stays whole. `80.0` where the web app writes `80` is a
    /// diff in the training log on every single save.
    func testWholeNumbersAreNotRewrittenAsDecimals() throws {
        let state = GymState(raw: ["w": .number(80), "half": .number(82.5),
                                   "ts": .int(1_758_124_800_000)])
        let text = String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
        XCTAssertTrue(text.contains("\"w\":80"), text)
        XCTAssertTrue(text.contains("\"half\":82.5"), text)
        XCTAssertTrue(text.contains("1758124800000"), text)
    }

    /// The server owns these. `active` in particular is device-local: a phone
    /// that uploaded its session in progress would put a half-finished workout
    /// on the web app's screen.
    func testTheWriteBodyDropsTheFieldsTheServerOwns() {
        let state = GymState(raw: ["_rev": .int(9), "_ts": .int(1),
                                   "active": .object(["id": .string("x")]),
                                   "unit": .string("kg")])
        let body = state.bodyForWrite
        XCTAssertNil(body["_rev"])
        XCTAssertNil(body["active"])
        XCTAssertEqual(body["unit"]?.stringValue, "kg")
        // `_ts` is kept: the server overwrites it, and it is what the merge
        // rule reads on the way there.
        XCTAssertEqual(body["_ts"]?.intValue, 1)
    }

    // MARK: - The week

    /// Javascript's weekday, not Swift's and not Python's. An off-by-one here
    /// shows a believable WRONG routine rather than an error.
    func testWeekdayNumbersAreJavascripts() {
        XCTAssertEqual(GymClock.jsWeekday(day: "2026-09-20"), 0, "Sunday is 0")
        XCTAssertEqual(GymClock.jsWeekday(day: "2026-09-21"), 1, "Monday is 1")
        XCTAssertEqual(GymClock.jsWeekday(day: "2026-09-19"), 6, "Saturday is 6")
    }

    /// A slot is legitimately written as a one-element array OR as a bare id,
    /// depending on which client wrote it. Both have to read.
    func testBothWeekSlotShapesRead() {
        let state = GymState(raw: ["week": .object([
            "1": .array([.string("r_a")]),
            "2": .string("r_b")
        ])])
        XCTAssertEqual(state.weekRoutineID(weekday: 1), "r_a")
        XCTAssertEqual(state.weekRoutineID(weekday: 2), "r_b")
        XCTAssertNil(state.weekRoutineID(weekday: 0))
    }

    /// `"rest"` is a deliberate rest day and must NOT fall through to the
    /// weekly default; an override that names a routine wins over it.
    func testDayPlanOverridesTheWeekAndRestDoesNotFallThrough() {
        let state = GymState(raw: [
            "week": .object(["1": .array([.string("r_a")])]),
            "dayPlan": .object(["2026-09-21": .string("rest"),
                                "2026-09-28": .string("r_c")])
        ])
        XCTAssertNil(state.routineID(on: "2026-09-21"))
        XCTAssertTrue(state.isDeclaredRest(on: "2026-09-21"))
        XCTAssertEqual(state.routineID(on: "2026-09-28"), "r_c")
        // An ordinary Monday still resolves through the week.
        XCTAssertEqual(state.routineID(on: "2026-09-14"), "r_a")
        XCTAssertFalse(state.isDeclaredRest(on: "2026-09-14"))
    }

    // MARK: - Body weight

    /// One entry per calendar day. A second entry for a day the array already
    /// has is what makes two devices disagree after a merge.
    func testBodyweightIsOnePerDayAndUpdatesInPlace() {
        var state = GymState(raw: ["bodyweight": .array([])])
        state.recordBodyweight(71.4, on: "2026-09-17", at: 100)
        state.recordBodyweight(70.9, on: "2026-09-18", at: 200)
        state.recordBodyweight(71.1, on: "2026-09-17", at: 300)

        let entries = state.bodyweight
        XCTAssertEqual(entries.count, 2)
        let seventeenth = entries.first { $0.day == "2026-09-17" }
        XCTAssertEqual(seventeenth?.weight, 71.1)
        XCTAssertEqual(seventeenth?.recordedAt, 300)
        // Stored ascending by day, the way openGym keeps it.
        let stored = state.raw["bodyweight"]?.arrayValue?
            .compactMap { $0.objectValue?["d"]?.stringValue }
        XCTAssertEqual(stored, ["2026-09-17", "2026-09-18"])
    }

    // MARK: - Sessions

    /// Both id fields, because openGym's own readers match on both: a session
    /// that merged two routines names only the first in the scalar.
    func testAFinishedSessionCarriesBothRoutineIdFields() {
        let workout = GymWorkout(raw: ["routineIds": .array([.string("a"), .string("b")]),
                                       "routineId": .string("a")])
        XCTAssertEqual(workout.routineIDs, ["a", "b"])

        let legacy = GymWorkout(raw: ["routineId": .string("c")])
        XCTAssertEqual(legacy.routineIDs, ["c"], "a legacy document still resolves")
    }

    /// Entries with no completed set are dropped at finish time and never
    /// reach the array - and the rows that survive keep their own flags.
    func testFinishingASessionWritesOpenGymsShape() throws {
        let active = ActiveWorkout(
            id: "w1", routineID: "r_a", routineName: "Ayush A",
            day: "2026-09-18", startedAt: 1_000, restSeconds: 90,
            entries: [
                ActiveWorkout.Entry(
                    exerciseID: "0043", name: "barbell squat",
                    target: ["id": .string("0043"), "sets": .int(2)],
                    sets: [ActiveWorkout.SetEntry(weight: 80, reps: 5, done: true),
                           ActiveWorkout.SetEntry(weight: 85, reps: 3, done: true),
                           ActiveWorkout.SetEntry(weight: 90, reps: 1, done: false)]),
                ActiveWorkout.Entry(
                    exerciseID: "0100", name: "skipped", target: [:],
                    sets: [ActiveWorkout.SetEntry(weight: 20, reps: 10, done: false)])
            ])

        let workout = active.finishedWorkout(endedAt: 4_000, bodyweight: 71.2)
        XCTAssertEqual(workout.day, "2026-09-18")
        XCTAssertEqual(workout.start, 1_000)
        XCTAssertEqual(workout.end, 4_000)
        XCTAssertEqual(workout.routineIDs, ["r_a"])
        XCTAssertEqual(workout.raw["routineId"]?.stringValue, "r_a")
        XCTAssertEqual(workout.bodyweight, 71.2)
        XCTAssertNotNil(workout.raw["prs"]?.arrayValue)

        XCTAssertEqual(workout.entries.count, 1, "an entry with no completed set is dropped")
        let entry = try XCTUnwrap(workout.entries.first)
        XCTAssertEqual(entry.id, "0043")
        XCTAssertEqual(entry.routineID, "r_a")
        XCTAssertEqual(entry.topWeight, 85, "the heaviest COMPLETED set, not the heaviest row")
        XCTAssertEqual(entry.sets.count, 3)
        XCTAssertEqual(entry.doneSets.count, 2)
        XCTAssertEqual(entry.sets.first?.raw["phase"]?.stringValue, "work")
        XCTAssertEqual(entry.sets.first?.raw["w"]?.intValue, 80)
    }

    /// A legacy row says `warmup: true` where a current one says
    /// `phase: "warmup"`. A warm-up counted as a working set is a wrong number
    /// on a page whose whole job is the numbers.
    func testBothWarmupSpellingsRead() {
        XCTAssertTrue(GymSetRow(raw: ["phase": .string("warmup")]).isWarmup)
        XCTAssertTrue(GymSetRow(raw: ["warmup": .bool(true)]).isWarmup)
        XCTAssertFalse(GymSetRow(raw: ["phase": .string("work")]).isWarmup)
        XCTAssertFalse(GymSetRow(raw: [:]).isWarmup)
    }
}

// MARK: - Merge

final class GymMergeTests: XCTestCase {

    private func state(ts: Int, _ extra: [String: JSONValue]) -> GymState {
        var raw: [String: JSONValue] = ["_ts": .int(ts), "_rev": .int(1)]
        for (key, value) in extra { raw[key] = value }
        return GymState(raw: raw)
    }

    /// The whole point: neither side's sessions may be lost, whichever is
    /// newer. This is what a 409 resolves to instead of an overwrite.
    func testWorkoutsAreUnionedByIdFromBothSides() {
        let local = state(ts: 200, ["workouts": .array([
            .object(["id": .string("w1"), "d": .string("2026-09-17")]),
            .object(["id": .string("w2"), "d": .string("2026-09-18")])
        ])])
        let server = state(ts: 100, ["workouts": .array([
            .object(["id": .string("w1"), "d": .string("2026-09-17")]),
            .object(["id": .string("w3"), "d": .string("2026-09-16")])
        ])])

        let merged = GymMerge.merge(local: local, server: server)
        XCTAssertEqual(Set(merged.workouts.map(\.id)), ["w1", "w2", "w3"])
        // Re-sorted by day then start, the way openGym re-sorts it.
        XCTAssertEqual(merged.workouts.map(\.day),
                       ["2026-09-18", "2026-09-17", "2026-09-16"],
                       "workouts read newest first")
    }

    /// Scalars come wholesale from the newer side - which is why a local edit
    /// bumps `_ts` before it goes anywhere.
    func testScalarsComeFromTheNewerSide() {
        let local = state(ts: 500, ["unit": .string("lb"),
                                    "week": .object(["1": .string("r_a")])])
        let server = state(ts: 100, ["unit": .string("kg"),
                                     "week": .object(["1": .string("r_z")])])
        XCTAssertEqual(GymMerge.merge(local: local, server: server).unit, "lb")
        XCTAssertEqual(GymMerge.merge(local: server, server: local).unit, "lb",
                       "which side is passed where must not decide it")
        XCTAssertEqual(GymMerge.merge(local: local, server: server)
                        .weekRoutineID(weekday: 1), "r_a")
    }

    /// Per day, the entry with the larger `t` wins - that is the tie-break
    /// between two devices that weighed in on the same morning.
    func testBodyweightTiesBreakOnTheEntryTimestamp() {
        let local = state(ts: 100, ["bodyweight": .array([
            .object(["d": .string("2026-09-18"), "w": .number(71), "t": .int(10)])
        ])])
        let server = state(ts: 200, ["bodyweight": .array([
            .object(["d": .string("2026-09-18"), "w": .number(72), "t": .int(99)]),
            .object(["d": .string("2026-09-17"), "w": .number(70), "t": .int(5)])
        ])])
        let merged = GymMerge.merge(local: local, server: server)
        XCTAssertEqual(merged.bodyweight.count, 2)
        XCTAssertEqual(merged.bodyweight.first { $0.day == "2026-09-18" }?.weight, 72)
    }

    /// The larger value, not the newer one. openGym's own rule.
    func testRememberedWeightsKeepTheHeavier() {
        let local = state(ts: 900, ["exWeights": .object([
            "0043": .object(["w": .number(80)])])])
        let server = state(ts: 100, ["exWeights": .object([
            "0043": .object(["w": .number(95)]),
            "0100": .object(["w": .number(20)])])])
        let merged = GymMerge.merge(local: local, server: server)
        XCTAssertEqual(merged.rememberedWeight(forExercise: "0043"), 95)
        XCTAssertEqual(merged.rememberedWeight(forExercise: "0100"), 20)
    }

    /// The server sets the revision. A merge result that carried one would be
    /// asserting something only the server can know.
    func testAMergeResultCarriesNoRevisionAndTheLaterTimestamp() {
        let merged = GymMerge.merge(local: state(ts: 700, [:]),
                                    server: state(ts: 300, [:]))
        XCTAssertNil(merged.raw["_rev"])
        XCTAssertEqual(merged.timestamp, 700)
    }
}

// MARK: - The demo backend and the fixture

final class GymDemoTests: XCTestCase {

    private func service() -> DemoATARUService { DemoATARUService(latency: .zero) }

    /// Demo has to answer the same four calls the mini does, or the screens
    /// are being reviewed against something production will not do.
    func testDemoResolvesTodayFromItsOwnDocument() async throws {
        let today = try await service().gymToday(date: "2026-09-21")   // a Monday
        XCTAssertEqual(today.weekday, "Monday")
        XCTAssertEqual(today.routine?.name, "Ayush A")
        XCTAssertFalse(today.isRestDay)
        // Every fixture exercise is a custom one, which is what makes the
        // names resolvable with no library endpoint anywhere.
        XCTAssertEqual(today.routine?.exercises.first?.name, "Leg Extension (Machine)")
    }

    /// Sunday is absent from the week, which is not the same as a declared
    /// rest day - and neither is drawn as "nothing is planned, ever".
    func testDemoSundayHasNoRoutine() async throws {
        let today = try await service().gymToday(date: "2026-09-20")
        XCTAssertTrue(today.isRestDay)
        XCTAssertEqual(today.weekday, "Sunday")
    }

    /// Saturday is stored as a BARE STRING in the fixture on purpose, so the
    /// both-shapes path is exercised somewhere that runs every build.
    func testDemoReadsTheBareStringWeekSlot() async throws {
        let today = try await service().gymToday(date: "2026-09-19")
        XCTAssertEqual(today.routine?.name, "Ayush C")
    }

    /// A write moves the revision by exactly one, and comes back as stored.
    func testDemoWriteAdvancesTheRevisionByOne() async throws {
        let service = service()
        let before = try await service.gymState()
        guard case .stored(let after) = try await service.gymWrite(
            state: before.state, baseRev: before.revision) else {
            return XCTFail("an identical document at the current revision must store")
        }
        XCTAssertEqual(after.revision, before.revision + 1)
        XCTAssertEqual(after.state.revision, before.revision + 1)
        let polled = try await service.gymRevision()
        XCTAssertEqual(polled, before.revision + 1)
    }

    /// And a stale one comes back as a conflict carrying what IS current -
    /// the document the caller merges against rather than overwrites.
    func testDemoRefusesAStaleWrite() async throws {
        let service = service()
        let current = try await service.gymState()
        guard case .conflict(let returned) = try await service.gymWrite(
            state: current.state, baseRev: current.revision - 1) else {
            return XCTFail("a stale baseRev must not be stored")
        }
        XCTAssertEqual(returned.revision, current.revision)
        XCTAssertEqual(returned.state.routines.count, 3)
    }

    /// The fixture is Arya's split by STRUCTURE and nobody's numbers. Three
    /// routines, six training days, Sunday off.
    func testTheFixtureCarriesTheThreeRoutines() async throws {
        let document = try await service().gymState()
        XCTAssertEqual(document.state.routines.map(\.name),
                       ["Ayush A", "Ayush B", "Ayush C"])
        XCTAssertEqual(document.state.routines.map(\.shortLabel), ["A", "B", "C"])
        let planned = (0...6).compactMap { document.state.weekRoutineID(weekday: $0) }
        XCTAssertEqual(planned.count, 6, "six sessions a week, Sunday absent")
        XCTAssertNil(document.state.weekRoutineID(weekday: 0))
        XCTAssertFalse(document.state.bodyweight.isEmpty)
        XCTAssertEqual(document.state.unit, "kg")
    }

    /// The last-logged column comes from the most recent SESSION, not from the
    /// routine's planned weight - the routine's number is a plan.
    func testTheFixtureHasSessionsToReadLastWeightsFrom() async throws {
        let state = try await service().gymState()
        let routine = try XCTUnwrap(state.state.routines.first)
        let last = try XCTUnwrap(state.state.lastWorkout(forRoutine: routine.id))
        let exercise = try XCTUnwrap(routine.exercises.first)
        XCTAssertNotNil(last.entry(forExercise: exercise.id)?.heaviestCompleted)
    }
}

// MARK: - Names

final class GymNameBookTests: XCTestCase {

    /// The built-in catalogue is not reachable from the phone, so names are
    /// accumulated from what the server has already resolved. An id that
    /// nothing resolves is shown AS the id - never as "Unknown", which hides
    /// which exercise it was.
    func testNamesAccumulateAndFallBackToTheId() {
        var book = GymNameBook()
        XCTAssertTrue(book.isUnresolved("0043"))
        XCTAssertEqual(book.name(for: "0043"), "0043")

        book.absorb(GymToday(date: "2026-09-18", weekday: "Friday",
                             routine: GymToday.Routine(
                                id: "r_b", name: "Ayush B",
                                exercises: [GymToday.Exercise(
                                    id: "0043", name: "barbell squat", sets: 5,
                                    reps: 5, weight: 80, mode: "reps",
                                    bodyweight: false)]),
                             lastWorkout: nil))
        XCTAssertEqual(book.name(for: "0043"), "barbell squat")
        XCTAssertFalse(book.isUnresolved("0043"))

        // A custom exercise carries its own name in the document.
        book.absorb(GymState(raw: ["customEx": .array([
            .object(["id": .string("cabc"), "n": .string("Ayush curl")])])]))
        XCTAssertEqual(book.name(for: "cabc"), "Ayush curl")
    }

    /// A server payload that fell back to the id must not be learned as a
    /// name - that would pin the wrong answer permanently.
    func testAnIdEchoedAsANameIsNotLearned() {
        var book = GymNameBook()
        book.absorb(GymToday(date: "2026-09-18", weekday: "Friday",
                             routine: GymToday.Routine(
                                id: "r_b", name: "Ayush B",
                                exercises: [GymToday.Exercise(
                                    id: "9999", name: "9999", sets: nil, reps: nil,
                                    weight: nil, mode: nil, bodyweight: nil)]),
                             lastWorkout: nil))
        XCTAssertTrue(book.isUnresolved("9999"))
    }
}

// MARK: - Formatting

final class GymFormatTests: XCTestCase {

    func testWeightsReadTheWayTheyAreLoaded() {
        XCTAssertEqual(GymFormat.number(80), "80")
        XCTAssertEqual(GymFormat.number(82.5), "82.5")
        XCTAssertEqual(GymFormat.weight(80, unit: "kg"), "80 kg")
        XCTAssertEqual(GymFormat.weight(nil, unit: "kg"), "-")
        // Zero is openGym's spelling for a bodyweight-only movement, and "0
        // kg" is not what that means.
        XCTAssertEqual(GymFormat.weight(0, unit: "kg"), "bodyweight")
    }

    func testTargetsReadAsTheyAreWrittenDown() {
        XCTAssertEqual(GymFormat.target(sets: 3, reps: 10), "3 x 10")
        XCTAssertEqual(GymFormat.target(sets: 1, reps: nil), "1 set")
        XCTAssertEqual(GymFormat.target(sets: 2, reps: nil), "2 sets")
        XCTAssertEqual(GymFormat.target(sets: nil, reps: 8), "")
    }
}

// MARK: - The week strip's label

/// Three of the seven things Arya reported on the week strip were one bug:
/// openGym's `emoji` field holds an ICON NAME, not an emoji, and it was being
/// rendered verbatim. "barbell isn't even fitting on one line, the circle
/// around abs is hugging way too close", and the wrapping is what staggered
/// the day cells off each other's baseline.
final class GymRoutineLabelTests: XCTestCase {

    private func routine(name: String, emoji: String?) -> GymRoutine {
        var raw: [String: JSONValue] = ["id": .string("r"), "name": .string(name)]
        if let emoji { raw["emoji"] = .string(emoji) }
        return GymRoutine(raw: raw)
    }

    /// The three values in Arya's own document, read from the live
    /// `/api/gym/state` on 2026-09-19.
    func testAnIconNameIsNotUsedAsALabel() {
        XCTAssertEqual(routine(name: "Ayush A", emoji: "barbell").shortLabel, "A")
        XCTAssertEqual(routine(name: "Ayush B", emoji: "pullup").shortLabel, "B")
        XCTAssertEqual(routine(name: "Ayush C", emoji: "abs").shortLabel, "C")
    }

    /// A real emoji still wins, including the multi-scalar ones - a ZWJ
    /// sequence and a skin tone are each ONE grapheme cluster, which is what
    /// the test is, so neither is mistaken for a word.
    func testARealEmojiIsKept() {
        XCTAssertEqual(routine(name: "Ayush A", emoji: "🏋").shortLabel, "🏋")
        XCTAssertEqual(routine(name: "Ayush A", emoji: "🏋🏽‍♂️").shortLabel, "🏋🏽‍♂️")
        XCTAssertEqual(routine(name: "Ayush A", emoji: "🇯🇵").shortLabel, "🇯🇵")
    }

    /// A one-character label of any kind is fine - it fits, which is the
    /// entire requirement.
    func testASingleLetterLabelIsKept() {
        XCTAssertEqual(routine(name: "Push Day", emoji: "P").shortLabel, "P")
    }

    /// No emoji at all, and the awkward names: the last word's first
    /// character, upper-cased, and never an empty string.
    func testTheFallbackIsOneCharacterOfTheName() {
        XCTAssertEqual(routine(name: "Ayush A", emoji: nil).shortLabel, "A")
        XCTAssertEqual(routine(name: "Ayush A", emoji: "").shortLabel, "A")
        XCTAssertEqual(routine(name: "lower body", emoji: nil).shortLabel, "B")
        XCTAssertEqual(routine(name: "", emoji: nil).shortLabel, "?")
    }

    /// Whatever the document holds, ONE character comes out. This is the
    /// property the strip's fixed cell height depends on.
    func testEveryLabelIsExactlyOneCharacter() {
        let awkward = ["barbell", "pullup", "abs", "", "lower body",
                       "Ayush A", "cardio & conditioning"]
        for name in awkward {
            for emoji in [nil, "", "barbell", "abs", "🏋"] as [String?] {
                let label = routine(name: name, emoji: emoji).shortLabel
                XCTAssertEqual(label.count, 1,
                               "\(name)/\(emoji ?? "nil") rendered as \(label)")
            }
        }
    }

    /// And the fixture carries the real values, so the bug is reproducible in
    /// Demo rather than only against Arya's own document - which is how it
    /// shipped in the first place.
    func testTheFixtureCarriesTheRealIconNames() async throws {
        let document = try await DemoATARUService(latency: .zero).gymState()
        XCTAssertEqual(document.state.routines.compactMap(\.emoji),
                       ["barbell", "pullup", "abs"])
        XCTAssertEqual(document.state.routines.map(\.shortLabel), ["A", "B", "C"])
    }
}

// MARK: - The rest timer

/// "The rest timer must survive leaving the screen or the app." It is stored
/// as an absolute end time on the session rather than as a countdown in a
/// view, so the two things that used to end it - the screen going away and the
/// app being suspended - cannot.
final class GymRestTimerTests: XCTestCase {

    private func session(restEndsAt: Int?) -> ActiveWorkout {
        ActiveWorkout(id: "w", routineID: "r", routineName: "Ayush C",
                      day: "2026-09-19", startedAt: 1_758_240_000_000,
                      restSeconds: 90, entries: [], restEndsAt: restEndsAt)
    }

    func testRemainingIsComputedFromTheClockNotCountedDown() {
        let now = Date(timeIntervalSince1970: 1_758_240_000)
        let workout = session(restEndsAt: GymClock.milliseconds(now.addingTimeInterval(90)))
        XCTAssertEqual(workout.restRemaining(at: now), 90)
        // Sixty seconds spent on another tile, or in another app, or with the
        // phone locked. The answer is the same either way, which is the whole
        // point of storing the END rather than the remainder.
        XCTAssertEqual(workout.restRemaining(at: now.addingTimeInterval(60)), 30)
    }

    /// A rest whose end has passed is over, not negative.
    func testAnElapsedRestIsOver() {
        let now = Date(timeIntervalSince1970: 1_758_240_000)
        let workout = session(restEndsAt: GymClock.milliseconds(now.addingTimeInterval(10)))
        XCTAssertNil(workout.restRemaining(at: now.addingTimeInterval(11)))
        XCTAssertNil(workout.restRemaining(at: now.addingTimeInterval(4_000)))
    }

    func testNothingRestingReadsAsNothingResting() {
        XCTAssertNil(session(restEndsAt: nil).restRemaining())
    }

    /// The session file is what carries it across a launch, so the field has
    /// to survive the round trip through disk.
    func testTheEndTimeSurvivesTheSessionFile() throws {
        let workout = session(restEndsAt: 1_758_240_090_000)
        let data = try JSONEncoder().encode(workout)
        let again = try JSONDecoder().decode(ActiveWorkout.self, from: data)
        XCTAssertEqual(again.restEndsAt, 1_758_240_090_000)
        XCTAssertEqual(again, workout)
    }

    /// A session file written before there was a rest timer decodes as one
    /// with nothing resting, rather than failing to decode at all - which
    /// would lose the sets in it.
    func testAnOlderSessionFileStillDecodes() throws {
        let json = """
        {"id":"w","routineID":"r","routineName":"Ayush C","day":"2026-09-19",
         "startedAt":1758240000000,"restSeconds":90,"entries":[]}
        """
        let decoded = try JSONDecoder().decode(ActiveWorkout.self, from: Data(json.utf8))
        XCTAssertNil(decoded.restEndsAt)
        XCTAssertNil(decoded.restRemaining())
    }
}

// MARK: - The exercise catalogue

/// `GET /api/gym/library` - openGym's 1324 built-in exercises, which the state
/// document deliberately does not carry. The shapes here are from the vault's
/// records/work/opengym/APP-API.md and were checked against the live route.
final class GymLibraryTests: XCTestCase {

    private let payload = """
    {"ok": true, "media_base": "https://gym.ataru.aryasasikumar.com/gif/",
     "exercises": [
       {"id": "0001", "name": "3/4 sit-up", "body_part": "waist",
        "equipment": "body weight", "gif": "0001-2gPfomN.gif"},
       {"id": "0043", "name": "barbell full squat", "body_part": "upper legs",
        "equipment": "barbell", "gif": "0043-qXTaZnJ.gif"},
       {"id": "9998", "name": "mystery move", "body_part": null,
        "equipment": null, "gif": null}
     ]}
    """

    private func library() throws -> GymLibrary {
        try JSONDecoder().decode(GymLibrary.self, from: Data(payload.utf8))
    }

    /// The route's keys are snake_case and the models are not. Getting this
    /// wrong gives an empty body part on every row rather than an error.
    func testTheRoutesKeysDecode() throws {
        let library = try library()
        XCTAssertEqual(library.mediaBase, "https://gym.ataru.aryasasikumar.com/gif/")
        XCTAssertEqual(library.exercises.count, 3)
        XCTAssertEqual(library.exercises[1].bodyPart, "upper legs")
        XCTAssertEqual(library.exercises[1].equipment, "barbell")
    }

    /// `media_base` + the bare filename. Nothing else - no path joining, which
    /// would drop a path component, and no slash rule, which would double one.
    func testAGifURLIsTheBaseAndTheFilename() throws {
        let library = try library()
        XCTAssertEqual(library.gifURL(for: library.exercises[1])?.absoluteString,
                       "https://gym.ataru.aryasasikumar.com/gif/0043-qXTaZnJ.gif")
    }

    /// A null `gif` is a real answer and must never become a URL - "draw the
    /// placeholder; never build a URL from a null".
    func testANullGifBuildsNoURL() throws {
        let library = try library()
        XCTAssertNil(library.gifURL(for: library.exercises[2]))
    }

    /// Every word has to land somewhere in the row, so a second word narrows.
    func testSearchMatchesNameBodyPartAndEquipment() throws {
        let library = try library()
        XCTAssertEqual(library.search("squat").map(\.id), ["0043"])
        XCTAssertEqual(library.search("waist").map(\.id), ["0001"])
        XCTAssertEqual(library.search("barbell upper").map(\.id), ["0043"])
        XCTAssertEqual(library.search("barbell waist").map(\.id), [])
        // Case folded, and an empty query is everything rather than nothing.
        XCTAssertEqual(library.search("BARBELL").map(\.id), ["0043"])
        XCTAssertEqual(library.search("   ").count, 3)
    }

    /// The server sorts case-folded with the id as the tiebreak; re-sorting in
    /// Swift over a lower-case dataset puts "3/4 sit-up" somewhere else. The
    /// list comes back in the order it arrived.
    func testTheServersOrderIsKept() throws {
        let library = try library()
        XCTAssertEqual(library.search("").map(\.id), ["0001", "0043", "9998"])
    }

    /// Custom exercises are NOT in the catalogue - they live in the state
    /// document, they have no media, and merging them client-side is what
    /// stops a day-old cache hiding one added two minutes ago.
    func testCustomExercisesAreReadOutOfTheDocument() {
        let state = GymState(raw: ["customEx": .array([
            .object(["id": .string("cm0kq3y1"), "n": .string("Ayush curl"),
                     "bp": .string("upper arms"), "eq": .string("dumbbell")]),
            .object(["n": .string("no id, no row")])
        ])])
        let entries = state.customLibraryEntries
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].id, "cm0kq3y1")
        XCTAssertEqual(entries[0].name, "Ayush curl")
        XCTAssertEqual(entries[0].tagline, "upper arms · dumbbell")
        XCTAssertNil(entries[0].gif)
    }

    /// Demo answers the library call too, with real ids and real filenames, so
    /// the picker and the thumbnails are reviewable without the orin.
    func testDemoServesACatalogue() async throws {
        let library = try await DemoATARUService(latency: .zero).gymLibrary()
        XCTAssertFalse(library.exercises.isEmpty)
        XCTAssertEqual(library.mediaBase, "https://gym.ataru.aryasasikumar.com/gif/")
        let squat = try XCTUnwrap(library.exercises.first { $0.id == "0043" })
        XCTAssertEqual(squat.name, "barbell full squat")
        XCTAssertEqual(library.gifURL(for: squat)?.absoluteString,
                       "https://gym.ataru.aryasasikumar.com/gif/0043-qXTaZnJ.gif")
    }

    /// And the Demo document points at one of them, so a Demo run shows a real
    /// animation next to the rows that correctly have none.
    func testTheFixtureUsesAtLeastOneCatalogueId() async throws {
        let document = try await DemoATARUService(latency: .zero).gymState()
        let ids = document.state.routines.flatMap { $0.exercises.map(\.id) }
        XCTAssertTrue(ids.contains("0043"), "no catalogue id in the fixture")
        XCTAssertTrue(ids.contains(where: { $0.hasPrefix("cdemo") }),
                      "the custom exercises went away")
    }
}

// MARK: - Adding from the catalogue

/// Adding by name always created a CUSTOM exercise, so picking "barbell full
/// squat" - which openGym has had all along at id "0043" - made a private
/// second copy under an id no other client could match. Adding from the
/// library writes openGym's own id and nothing else.
@MainActor
final class GymAddExerciseTests: XCTestCase {

    private func store() async -> GymStore {
        let store = GymStore()
        store.configure(service: DemoATARUService(latency: .zero), cacheRoot: nil)
        await store.refresh()
        return store
    }

    func testAddingFromTheLibraryWritesTheCatalogueIdAndNoCustomRow() async throws {
        let store = await store()
        let routineID = try XCTUnwrap(store.state?.routines.first?.id)
        let customsBefore = store.state?.customLibraryEntries.count ?? 0
        let entry = GymLibraryEntry(id: "0032", name: "barbell deadlift",
                                    bodyPart: "upper legs", equipment: "barbell",
                                    gif: "0032-ila4NZS.gif")

        let stored = await store.addLibraryExercise(entry, to: routineID)
        XCTAssertTrue(stored)

        let routine = try XCTUnwrap(store.state?.routine(id: routineID))
        let added = try XCTUnwrap(routine.exercises.last)
        XCTAssertEqual(added.id, "0032")
        XCTAssertEqual(added.sets, 3)
        XCTAssertEqual(added.reps, 10)
        // Nothing was added to the profile's own catalogue: a catalogue id is
        // resolved by every client already.
        XCTAssertEqual(store.state?.customLibraryEntries.count, customsBefore)
    }

    /// The config carries the four keys openGym writes unconditionally and no
    /// others. Inventing `bodyweight`, `mode` or `side` is how a client writes
    /// a document the web app then reads differently.
    func testTheAddedConfigCarriesOnlyTheKeysOpenGymWrites() async throws {
        let store = await store()
        let routineID = try XCTUnwrap(store.state?.routines.first?.id)
        let entry = GymLibraryEntry(id: "0652", name: "pull-up", bodyPart: "back",
                                    equipment: "body weight", gif: "0652-lBDjFxJ.gif")
        let stored = await store.addLibraryExercise(entry, to: routineID)
        XCTAssertTrue(stored)
        let added = try XCTUnwrap(store.state?.routine(id: routineID)?.exercises.last)
        XCTAssertEqual(Set(added.raw.keys), ["id", "sets", "reps", "weight"])
    }

    /// Typing a name the catalogue does not have still makes a real openGym
    /// custom exercise, exactly as before - that path did not change.
    func testACustomNameStillBecomesACustomExercise() async throws {
        let store = await store()
        let routineID = try XCTUnwrap(store.state?.routines.first?.id)
        let before = store.state?.customLibraryEntries.count ?? 0

        let stored = await store.addExercise(named: "Ayush curl", to: routineID)
        XCTAssertTrue(stored)

        XCTAssertEqual(store.state?.customLibraryEntries.count, before + 1)
        let added = try XCTUnwrap(store.state?.routine(id: routineID)?.exercises.last)
        XCTAssertTrue(added.id.hasPrefix("c"), "a custom id is \"c\" plus a uid")
        XCTAssertEqual(store.displayName(for: added.id), "Ayush curl")
    }

    /// The library resolves names for ids the name book has never seen, which
    /// is what stops a catalogue exercise rendering as "0043".
    func testTheLibraryNamesCatalogueIds() async throws {
        let store = await store()
        XCTAssertEqual(store.displayName(for: "0043"), "0043",
                       "nothing is known before the library has loaded")
        await store.loadLibrary()
        XCTAssertEqual(store.displayName(for: "0043"), "barbell full squat")
        XCTAssertEqual(store.gifURL(forExercise: "0043")?.absoluteString,
                       "https://gym.ataru.aryasasikumar.com/gif/0043-qXTaZnJ.gif")
        // An id in neither the catalogue nor the document is shown AS the id -
        // never "Unknown", which hides which exercise it was.
        XCTAssertEqual(store.displayName(for: "9999"), "9999")
        XCTAssertNil(store.gifURL(forExercise: "9999"))
    }

    /// The picker searches one merged list, and his own exercises come first.
    func testTheMergedPickerListPutsCustomsFirst() async throws {
        let store = await store()
        await store.loadLibrary()
        let all = store.searchableExercises(matching: "")
        let firstCustom = try XCTUnwrap(all.firstIndex { $0.id.hasPrefix("cdemo") })
        let firstCatalogue = try XCTUnwrap(all.firstIndex { $0.id == "0001" })
        XCTAssertLessThan(firstCustom, firstCatalogue)
        // And a search reaches both halves.
        XCTAssertTrue(store.searchableExercises(matching: "zercher")
            .contains { $0.name == "Zercher Squat" })
        XCTAssertTrue(store.searchableExercises(matching: "barbell full")
            .contains { $0.id == "0043" })
    }

    /// Discarding a session removes it from the phone, which is the only copy
    /// there is - openGym deletes `active` on every write, so it was never
    /// sent anywhere.
    func testDiscardingASessionClearsIt() async throws {
        let store = await store()
        store.startWorkout()
        XCTAssertNotNil(store.active)
        store.discardWorkout()
        XCTAssertNil(store.active)
        XCTAssertNil(ActiveWorkoutStore.load())
    }
}
