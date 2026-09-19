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
