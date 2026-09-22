import Foundation

// openGym's state document, as the app reads and writes it.
//
// The authority for every shape in this file is the vault's
// records/work/opengym/APP-API.md, which was written from openGym's own source
// rather than from a sample document. Three things in here look like details
// and are not:
//
//   * `week` is keyed by JAVASCRIPT's weekday - "0" is Sunday. Swift's
//     Calendar is 1-based. An off-by-one gives a plausible wrong routine on a
//     Monday rather than an error, so the conversion is written once, here.
//   * a `week` slot is EITHER a bare routine id OR a one-element array. Both
//     are read, and a slot is written back in the shape it was found in, so a
//     client of one vintage does not rewrite the document for the other.
//   * every unknown key survives a round trip. See JSONValue.
//
// PRIVACY: this is health-class data (vault CLAUDE.md). Nothing in this file
// or the screens above it logs a weight, a count or an exercise, and nothing
// leaves the phone except the GET/PUT to Arya's own ATARU server.

// MARK: - Days, ids and clocks

enum GymClock {
    /// `YYYY-MM-DD` in the phone's own timezone.
    ///
    /// LOCAL COMPONENTS, NEVER `Date.toISOString()`. openGym builds these from
    /// local components too, and a UTC day puts a late-evening session on
    /// tomorrow - which reads as a workout Arya did not do on a day he did not
    /// train.
    static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func day(_ date: Date = Date()) -> String { dayFormatter.string(from: date) }

    static func date(fromDay day: String) -> Date? { dayFormatter.date(from: day) }

    /// Milliseconds since the epoch - what `_ts`, `start`, `end` and a
    /// bodyweight entry's `t` are measured in.
    static func milliseconds(_ date: Date = Date()) -> Int {
        Int(date.timeIntervalSince1970 * 1000)
    }

    /// Midday on a training day, in milliseconds, in the phone's own zone.
    ///
    /// What a workout logged after the fact uses for `start`. Nil for a string
    /// that is not a day, which the caller answers with the current clock.
    ///
    /// Midday rather than a plausible evening: the time is a placeholder
    /// either way, so it should be one no reader mistakes for a recorded time,
    /// and midday is far enough from both boundaries that no zone or
    /// daylight-saving shift can move the session onto the neighbouring day.
    static func middayMilliseconds(onDay day: String) -> Int? {
        guard let midnight = date(fromDay: day) else { return nil }
        return milliseconds(midnight.addingTimeInterval(12 * 60 * 60))
    }

    /// Javascript's `Date.getDay()`: 0 = Sunday through 6 = Saturday.
    static func jsWeekday(_ date: Date) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        // Calendar counts 1 = Sunday, so the conversion is one subtraction -
        // and it is the whole of the difference between the right routine and
        // a believable wrong one.
        return calendar.component(.weekday, from: date) - 1
    }

    static func jsWeekday(day: String) -> Int? {
        date(fromDay: day).map(jsWeekday)
    }

    /// openGym's own id generator (`frontend/src/lib/format.js`): base-36
    /// milliseconds plus five random base-36 characters. Not a UUID - one
    /// would work mechanically and would stand out in the file.
    static func uid() -> String {
        let stamp = String(milliseconds(), radix: 36)
        let alphabet = Array("0123456789abcdefghijklmnopqrstuvwxyz")
        let tail = (0..<5).map { _ in alphabet.randomElement() ?? "0" }
        return stamp + String(tail)
    }
}

// MARK: - Units

/// Pounds, everywhere, and the arithmetic that makes that safe.
///
/// ## The document is not in a canonical unit
///
/// openGym stores a bare number per weight and a single `unit` string beside
/// it (`frontend/src/store/useStore.js`, `DEF.unit = 'kg'`). There is no
/// canonical kilogram anywhere in the file: a `w` of 60 means 60 of whatever
/// `unit` currently says. Its settings screen offers both answers when the
/// unit is switched - "convert the numbers" walks every stored weight
/// (`lib/units.js:convertStateUnit`), "keep the numbers, change the label"
/// does not.
///
/// So this app cannot read a weight without reading `unit` in the same breath,
/// and it cannot write one without putting it back into `unit`. That is what
/// the two directions below are for, and why every screen goes through them
/// rather than through a bare `Double`.
///
/// ## Why the constant and the rounding are copied rather than chosen
///
/// Both are openGym's own, to the last digit: `2.2046226218`, pounds to the
/// nearest 0.5 and kilograms to the nearest 0.25. A different factor or a
/// different rounding would mean a weight typed on the phone and read in the
/// browser disagree in the last place - and 82.5 becoming 82.4 on a screen
/// whose whole job is the number is the one mistake nobody would report as a
/// bug, because it looks like a number.
enum GymUnits {

    /// What every field, label, row and chart in this app shows and accepts.
    ///
    /// Arya asked for pounds (2026-09-21) and there is deliberately no
    /// per-screen override and no setting: a training app that shows two units
    /// is a training app that gets a lift wrong.
    static let display = "lb"

    /// openGym's `LB_PER_KG` (`frontend/src/lib/units.js`).
    static let poundsPerKilogram = 2.2046226218

    /// The units a conversion is defined for. Anything else is left ALONE -
    /// relabelling a number is wrong and scaling it by a guessed factor is
    /// worse, so an unrecognised unit passes through and the label says what
    /// the document says.
    static let known: Set<String> = ["kg", "lb"]

    static func convert(_ value: Double?, from: String, to: String) -> Double? {
        guard let value, value.isFinite else { return value }
        guard from != to, known.contains(from), known.contains(to) else { return value }
        return to == "lb"
            ? (value * poundsPerKilogram * 2).rounded() / 2
            : (value / poundsPerKilogram * 4).rounded() / 4
    }

    /// A number out of the document, in pounds - what a screen shows.
    static func toDisplay(_ value: Double?, storedIn unit: String) -> Double? {
        convert(value, from: unit, to: display)
    }

    /// A number typed in pounds, in the document's unit - what a write stores.
    ///
    /// Zero survives unchanged in both directions, which matters: zero is
    /// openGym's spelling for a bodyweight-only movement, not a light one.
    static func fromDisplay(_ value: Double?, storedIn unit: String) -> Double? {
        convert(value, from: display, to: unit)
    }
}

// MARK: - Exercise config

/// One element of a routine's `ex` array.
///
/// Most keys are present only when they differ from a default, so ABSENT IS
/// NOT ZERO and absent is not false. Everything this app does not understand
/// stays in `raw` and goes back up untouched.
struct GymExerciseConfig: Identifiable, Equatable, Codable {
    var raw: [String: JSONValue]

    init(raw: [String: JSONValue]) { self.raw = raw }

    init(from decoder: Decoder) throws {
        raw = try decoder.singleValueContainer().decode([String: JSONValue].self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(raw)
    }

    var id: String { raw["id"]?.stringValue ?? "" }
    var sets: Int { raw["sets"]?.intValue ?? 1 }
    var reps: Int? { raw["reps"]?.intValue }
    var seconds: Int? { raw["sec"]?.intValue }
    var minutes: Double? { raw["min"]?.doubleValue }
    var speed: Double? { raw["speed"]?.doubleValue }
    var weight: Double? { raw["weight"]?.doubleValue }
    var note: String? { raw["note"]?.stringValue }

    /// `reps`, `time` or `cardio`.
    ///
    /// Resolved the way `/api/gym/today` resolves it, minus the catalogue this
    /// app has no endpoint for: openGym stores `mode` only for the reps/time
    /// toggle, and a cardio config carries `min`/`speed` and no mode at all.
    /// A catalogue cardio exercise stored with no `min` yet reads as reps
    /// here and as cardio on the Today page, which is the server's answer and
    /// the one the workout screen uses.
    var mode: String {
        if let mode = raw["mode"]?.stringValue, mode == "reps" || mode == "time" {
            return mode
        }
        if raw["min"] != nil || raw["speed"] != nil { return "cardio" }
        return "reps"
    }

    mutating func setSets(_ value: Int) { raw["sets"] = .int(max(1, value)) }

    mutating func setReps(_ value: Int?) {
        if let value { raw["reps"] = .int(max(0, value)) } else { raw["reps"] = nil }
    }

    /// Writes the weight, and REMOVES the key when there is none.
    ///
    /// A bodyweight-only exercise carries `weight: 0` in openGym and a cardio
    /// config carries no weight key at all; writing an explicit null would be
    /// a third thing the web app never produces.
    mutating func setWeight(_ value: Double?) {
        if let value { raw["weight"] = .number(value) } else { raw["weight"] = nil }
    }
}

// MARK: - Routine

struct GymRoutine: Identifiable, Equatable, Codable {
    var raw: [String: JSONValue]

    init(raw: [String: JSONValue]) { self.raw = raw }

    init(from decoder: Decoder) throws {
        raw = try decoder.singleValueContainer().decode([String: JSONValue].self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(raw)
    }

    var id: String { raw["id"]?.stringValue ?? "" }
    var name: String { raw["name"]?.stringValue ?? "" }
    var emoji: String? { raw["emoji"]?.stringValue }

    /// `ex`, not `exercises`. That is openGym's field name and reading the
    /// wrong one renders every routine as empty.
    var exercises: [GymExerciseConfig] {
        (raw["ex"]?.arrayValue ?? []).compactMap {
            $0.objectValue.map(GymExerciseConfig.init(raw:))
        }
    }

    mutating func setExercises(_ list: [GymExerciseConfig]) {
        raw["ex"] = .array(list.map { .object($0.raw) })
    }

    /// ONE character for the week strip, and never more than one.
    ///
    /// ## `emoji` is not an emoji
    ///
    /// The field is called `emoji` and openGym does not put an emoji in it. It
    /// stores the NAME of the icon the web app draws - Arya's three routines
    /// carry `"barbell"`, `"pullup"` and `"abs"` - so trusting the field
    /// verbatim put whole words into a seven-cell strip. That is exactly what
    /// he saw: "barbell isn't even fitting on one line", "the circle around
    /// abs is hugging way too close", and the wrapping pushed each day cell to
    /// a different height, which is the staggering.
    ///
    /// The test is structural rather than a list of known icon names, which
    /// would go stale the moment openGym adds one: a label is taken verbatim
    /// only when it is a SINGLE grapheme cluster. A real emoji passes (a flag,
    /// a skin-toned lifter and a ZWJ sequence are each one cluster); a bare
    /// letter passes; `"barbell"` does not, and falls through to the name.
    ///
    /// The fallback is the last word's first character - "Ayush B" reads as B,
    /// which is how Arya names them. The full name is shown under the strip
    /// for today, so nothing is actually hidden by the shortening.
    var shortLabel: String {
        if let emoji, emoji.count == 1 { return emoji }
        guard let last = name.split(separator: " ").last, let first = last.first else {
            return "?"
        }
        return String(first).uppercased()
    }
}

// MARK: - Finished sessions

struct GymSetRow: Equatable, Codable {
    var raw: [String: JSONValue]

    init(raw: [String: JSONValue]) { self.raw = raw }

    init(from decoder: Decoder) throws {
        raw = try decoder.singleValueContainer().decode([String: JSONValue].self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(raw)
    }

    var weight: Double? { raw["w"]?.doubleValue }
    var reps: Int? { raw["r"]?.intValue }
    var done: Bool { raw["done"]?.boolValue ?? false }
    var seconds: Int? { raw["sec"]?.intValue }

    /// `warmup` or `work`. Legacy documents carry `warmup: true` instead of a
    /// phase, and both are read - a warm-up set counted as a working set is a
    /// wrong number on a page whose whole job is the numbers.
    var isWarmup: Bool {
        if let phase = raw["phase"]?.stringValue { return phase == "warmup" }
        return raw["warmup"]?.boolValue ?? false
    }
}

struct GymWorkoutEntry: Identifiable, Equatable, Codable {
    var raw: [String: JSONValue]

    init(raw: [String: JSONValue]) { self.raw = raw }

    init(from decoder: Decoder) throws {
        raw = try decoder.singleValueContainer().decode([String: JSONValue].self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(raw)
    }

    var id: String { raw["id"]?.stringValue ?? "" }
    var routineID: String? { raw["rid"]?.stringValue }
    var topWeight: Double? { raw["topW"]?.doubleValue }

    var sets: [GymSetRow] {
        (raw["sets"]?.arrayValue ?? []).compactMap {
            $0.objectValue.map(GymSetRow.init(raw:))
        }
    }

    var doneSets: [GymSetRow] { sets.filter(\.done) }

    /// The heaviest completed working set, which is what "last time" means on
    /// the Today page.
    var heaviestCompleted: Double? {
        doneSets.compactMap(\.weight).max() ?? topWeight
    }
}

struct GymWorkout: Identifiable, Equatable, Codable {
    var raw: [String: JSONValue]

    init(raw: [String: JSONValue]) { self.raw = raw }

    init(from decoder: Decoder) throws {
        raw = try decoder.singleValueContainer().decode([String: JSONValue].self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(raw)
    }

    var id: String { raw["id"]?.stringValue ?? "" }
    /// The training DAY, `YYYY-MM-DD`.
    var day: String { raw["d"]?.stringValue ?? "" }
    var name: String { raw["name"]?.stringValue ?? "" }
    var start: Int? { raw["start"]?.intValue }
    var end: Int? { raw["end"]?.intValue }
    var bodyweight: Double? { raw["bw"]?.doubleValue }

    /// True when this session was recorded after the fact rather than logged
    /// at the rack.
    ///
    /// The key is ATARU's own, because openGym has none to reuse: its own
    /// backfill flag lives on the ACTIVE session (`frontend/src/lib/backfill.js`),
    /// and the server deletes `active` on every write - so nothing survives
    /// into the stored workout for a reader to find.
    ///
    /// Written only when true, which is openGym's own convention for an
    /// optional flag ("written only when set/true, so a single-routine
    /// non-excluded session is byte-for-byte the shape it always was",
    /// `lib/finish-workout.js`). It round-trips through the web app because
    /// nothing there strips a key it does not understand: the store loads with
    /// `Object.assign(clone(DEF), JSON.parse(raw))`, the sync merge spreads
    /// whole workout objects (`lib/sync-merge.js:unionById`), and both the api
    /// and the bridge write the document back verbatim. The one place it could
    /// be dropped is openGym REBUILDING this workout from a session, which it
    /// only does at finish time - and a lost mark is a lost mark, not a lost
    /// workout.
    var isLoggedLater: Bool { raw["loggedLater"]?.boolValue ?? false }

    /// Every routine the session drew on.
    ///
    /// `routineIds` is the real list and `routineId` is a legacy mirror of its
    /// first element, so both are read: a session that merged two routines
    /// names only the first in the scalar, and matching the scalar alone
    /// reports "never trained" for the second.
    var routineIDs: [String] {
        var ids = (raw["routineIds"]?.arrayValue ?? []).compactMap(\.stringValue)
        if let scalar = raw["routineId"]?.stringValue, !ids.contains(scalar) {
            ids.append(scalar)
        }
        return ids
    }

    var entries: [GymWorkoutEntry] {
        (raw["entries"]?.arrayValue ?? []).compactMap {
            $0.objectValue.map(GymWorkoutEntry.init(raw:))
        }
    }

    var totalSets: Int { entries.reduce(0) { $0 + $1.doneSets.count } }

    var durationMinutes: Int? {
        guard let start, let end, end > start else { return nil }
        return (end - start) / 60_000
    }

    func entry(forExercise id: String) -> GymWorkoutEntry? {
        entries.first { $0.id == id }
    }

    /// Day first, start second - `d` is what a human means by "last time",
    /// and `start` only orders two sessions inside one day.
    var sortKey: String { day + String(format: "%015d", start ?? 0) }
}

// MARK: - Bodyweight

struct GymBodyweightEntry: Identifiable, Equatable, Codable {
    var day: String
    var weight: Double
    var recordedAt: Int

    var id: String { day }
}

// MARK: - The document

/// openGym's whole state, held as it arrived and mutated in place.
struct GymState: Equatable, Codable {
    private(set) var raw: [String: JSONValue]

    init(raw: [String: JSONValue]) { self.raw = raw }

    init(from decoder: Decoder) throws {
        raw = try decoder.singleValueContainer().decode([String: JSONValue].self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(raw)
    }

    // MARK: Reading

    var revision: Int { raw["_rev"]?.intValue ?? 0 }
    var timestamp: Int { raw["_ts"]?.intValue ?? 0 }

    /// `kg` or `lb`. There is no per-entry unit anywhere in the document -
    /// every weight in it is in this one.
    var unit: String { raw["unit"]?.stringValue ?? "kg" }

    var restSeconds: Int { raw["restSec"]?.intValue ?? 90 }

    var routines: [GymRoutine] {
        (raw["routines"]?.arrayValue ?? []).compactMap {
            $0.objectValue.map(GymRoutine.init(raw:))
        }
    }

    func routine(id: String) -> GymRoutine? { routines.first { $0.id == id } }

    /// Newest first.
    var workouts: [GymWorkout] {
        (raw["workouts"]?.arrayValue ?? [])
            .compactMap { $0.objectValue.map(GymWorkout.init(raw:)) }
            .sorted { $0.sortKey > $1.sortKey }
    }

    /// Newest first.
    var bodyweight: [GymBodyweightEntry] {
        (raw["bodyweight"]?.arrayValue ?? []).compactMap { value in
            guard let object = value.objectValue,
                  let day = object["d"]?.stringValue,
                  let weight = object["w"]?.doubleValue else { return nil }
            return GymBodyweightEntry(day: day, weight: weight,
                                      recordedAt: object["t"]?.intValue ?? 0)
        }
        .sorted { $0.day > $1.day }
    }

    /// Display names for custom exercises, by id. The built-in catalogue's
    /// 1300 names are NOT in this document - see GymNameBook.
    var customExerciseNames: [String: String] {
        var names: [String: String] = [:]
        for value in raw["customEx"]?.arrayValue ?? [] {
            guard let object = value.objectValue,
                  let id = object["id"]?.stringValue,
                  let name = object["n"]?.stringValue else { continue }
            names[id] = name
        }
        return names
    }

    /// The routine planned for a date, resolved openGym's way: a `dayPlan`
    /// override beats the weekly default, and the literal `"rest"` is a
    /// DELIBERATE rest day that must not fall through to the week.
    func routineID(on day: String) -> String? {
        if let plan = raw["dayPlan"]?.objectValue, let override = plan[day]?.stringValue {
            if override == "rest" { return nil }
            if !override.isEmpty { return override }
        }
        guard let weekday = GymClock.jsWeekday(day: day) else { return nil }
        return weekRoutineID(weekday: weekday)
    }

    /// `week[jsWeekday]`, accepting both shapes the document is written in.
    func weekRoutineID(weekday: Int) -> String? {
        guard let week = raw["week"]?.objectValue, let slot = week[String(weekday)] else {
            return nil
        }
        if let array = slot.arrayValue { return array.first?.stringValue }
        if let id = slot.stringValue, !id.isEmpty { return id }
        return nil
    }

    /// True when the date is a declared rest day rather than merely unplanned.
    func isDeclaredRest(on day: String) -> Bool {
        raw["dayPlan"]?.objectValue?[day]?.stringValue == "rest"
    }

    /// The most recent finished session that drew on a routine.
    func lastWorkout(forRoutine id: String) -> GymWorkout? {
        workouts.first { $0.routineIDs.contains(id) }
    }

    /// The day a routine was last trained, or nil for one that never has been.
    func lastDay(forRoutine id: String) -> String? {
        lastWorkout(forRoutine: id)?.day
    }

    /// The session completed most recently, by day and then start time.
    ///
    /// A session logged after the fact counts, because it is a session that
    /// happened - and it counts at the day it happened on, not the day it was
    /// typed in, which is what `sortKey` already means.
    var mostRecentWorkout: GymWorkout? { workouts.first }

    /// The routine to do next, following COMPLETION rather than the calendar.
    ///
    /// ## Why not the week
    ///
    /// "I worked out yesterday but the app had no way of me selecting a
    /// routine and doing it today. I ended up doing Ayush A yesterday."
    /// Yesterday was Sunday, the week's rest day, so the calendar had nothing
    /// to offer and the app offered nothing back. Worse, the calendar had
    /// already gone out of step: doing A on Sunday makes Monday's A a repeat.
    ///
    /// So the loop is the program's own - the order the routines are written
    /// down in - and the position in it is the one thing that is actually
    /// known: what was finished last. After A comes B whatever day it is, and
    /// a week off leaves the loop exactly where he left it rather than
    /// silently advancing three routines.
    ///
    /// `week` is still read, but only as the rest-day MARKER on the card (see
    /// `GymTodayPage`), never as a gate on what can be started.
    ///
    /// Nothing ever completed - which is where Arya's own document starts -
    /// answers the first routine rather than nil: a program with routines in
    /// it always has a next one.
    var nextRoutineID: String? {
        let loop = routines
        guard let first = loop.first else { return nil }
        guard let previous = mostRecentWorkout?.routineIDs.first,
              let index = loop.firstIndex(where: { $0.id == previous }) else {
            // Never trained, or last trained a routine that has since been
            // deleted. Start the loop again rather than guessing at a gap.
            return first.id
        }
        return loop[(index + 1) % loop.count].id
    }

    /// The most recent entry for an exercise, in ANY session - what a set row
    /// is prefilled from.
    func lastEntry(forExercise id: String) -> GymWorkoutEntry? {
        for workout in workouts {
            if let entry = workout.entry(forExercise: id), !entry.doneSets.isEmpty {
                return entry
            }
        }
        return nil
    }

    /// openGym's own "last used weight per exercise" map, read as a fallback
    /// when no session in this document carries the exercise. Never written:
    /// the merge rule keeps the LARGER of two values for a key, so it is a
    /// best-ever rather than a last, and writing it from here would quietly
    /// turn one into the other.
    func rememberedWeight(forExercise id: String) -> Double? {
        raw["exWeights"]?.objectValue?[id]?.objectValue?["w"]?.doubleValue
    }

    // MARK: Writing

    /// Marks this side as the one that changed, for the merge rule.
    ///
    /// The server overwrites `_ts` on every write, so this is not sent for the
    /// server's benefit - it is what makes a 409 merge treat the phone's edit
    /// as the newer one rather than silently taking the other side's scalars.
    mutating func touch(at milliseconds: Int = GymClock.milliseconds()) {
        raw["_ts"] = .int(milliseconds)
    }

    mutating func setRoutines(_ list: [GymRoutine]) {
        raw["routines"] = .array(list.map { .object($0.raw) })
    }

    mutating func replaceRoutine(_ routine: GymRoutine) {
        var list = routines
        guard let index = list.firstIndex(where: { $0.id == routine.id }) else { return }
        list[index] = routine
        setRoutines(list)
    }

    /// Files a session where its DAY and start time put it.
    ///
    /// openGym keeps `workouts` ascending and reverses it for History, so a
    /// session logged for last Sunday cannot simply be pushed onto the end -
    /// its own backfill does the same insertion
    /// (`frontend/src/lib/backfill.js:insertChronological`), and after
    /// anything sharing the same instant, which is what the `<=` there and the
    /// `>` here both mean.
    ///
    /// For a session finished just now this IS an append, which is why it
    /// replaced `appendWorkout` outright rather than sitting beside it: two
    /// insertion paths is how one of them stops being used and starts being
    /// wrong.
    ///
    /// Never replaces the array - that is how a phone deletes a month of
    /// training in one PUT.
    mutating func insertWorkout(_ workout: GymWorkout) {
        var list = raw["workouts"]?.arrayValue ?? []
        let key = workout.sortKey
        var index = list.count
        while index > 0,
              GymWorkout(raw: list[index - 1].objectValue ?? [:]).sortKey > key {
            index -= 1
        }
        list.insert(.object(workout.raw), at: index)
        raw["workouts"] = .array(list)
    }

    /// One entry per calendar day: the day's entry is updated in place when it
    /// exists, and appended when it does not. A second entry for a day the
    /// array already has is what makes two devices disagree after a merge.
    mutating func recordBodyweight(_ weight: Double, on day: String,
                                   at milliseconds: Int = GymClock.milliseconds()) {
        var list = raw["bodyweight"]?.arrayValue ?? []
        var updated = false
        for index in list.indices {
            guard var object = list[index].objectValue,
                  object["d"]?.stringValue == day else { continue }
            object["w"] = .number(weight)
            object["t"] = .int(milliseconds)
            list[index] = .object(object)
            updated = true
            break
        }
        if !updated {
            list.append(.object(["d": .string(day), "w": .number(weight),
                                 "t": .int(milliseconds)]))
        }
        // Ascending by day, which is the order openGym keeps it in.
        list.sort { ($0.objectValue?["d"]?.stringValue ?? "")
                  < ($1.objectValue?["d"]?.stringValue ?? "") }
        raw["bodyweight"] = .array(list)
    }

    /// Adds a custom exercise to the profile's catalogue.
    ///
    /// Custom rather than built-in because the ATARU server exposes no
    /// endpoint for openGym's 1324-name library - see GymRoutineDetail for
    /// what that costs and what is deliberately not pretended.
    mutating func addCustomExercise(id: String, name: String) {
        var list = raw["customEx"]?.arrayValue ?? []
        list.append(.object([
            "id": .string(id), "n": .string(name), "bp": .string(""),
            "eq": .string(""), "desc": .string(""), "tg": .string(""),
            "sm": .array([]), "primaries": .array([]), "secondaries": .array([]),
            "muscleGroups": .array([]), "custom": .bool(true)
        ]))
        raw["customEx"] = .array(list)
    }

    /// The body of a PUT.
    ///
    /// `_rev` and `active` are stripped: the server sets the first and deletes
    /// the second on every write, and `active` is device-local by design - a
    /// phone that uploaded its in-progress session would put a half-finished
    /// workout on the web app's screen.
    var bodyForWrite: [String: JSONValue] {
        var body = raw
        body["_rev"] = nil
        body["active"] = nil
        return body
    }
}

// MARK: - Merge

/// openGym's own merge rule (`frontend/src/lib/sync-merge.js`), applied when a
/// PUT comes back 409.
///
/// The one thing this must never do is re-send the phone's copy with the
/// server's new revision. That is exactly the silent overwrite the revision
/// check exists to prevent: the web app's write would vanish and nothing
/// anywhere would say so.
enum GymMerge {

    static func merge(local: GymState, server: GymState) -> GymState {
        let localNewer = local.timestamp >= server.timestamp
        // Everything not named below - scalars, settings, week, dayPlan, wc,
        // reminder - is taken WHOLESALE from the newer side.
        var merged = localNewer ? local.raw : server.raw
        let localRaw = local.raw
        let serverRaw = server.raw

        for key in ["workouts", "routines", "customEx", "equipProfiles", "gymCards"] {
            merged[key] = unionByID(localRaw[key], serverRaw[key], localNewer: localNewer)
        }
        merged["bodyweight"] = unionBodyweight(localRaw["bodyweight"],
                                               serverRaw["bodyweight"])
        merged["favEx"] = unionFavourites(localRaw["favEx"], serverRaw["favEx"],
                                          localNewer: localNewer)
        merged["exWeights"] = unionHeavier(localRaw["exWeights"], serverRaw["exWeights"])
        for key in ["exNotes", "barWeights"] {
            merged[key] = unionKeys(localRaw[key], serverRaw[key], localNewer: localNewer)
        }

        // Re-sorted by day then start, the way openGym re-sorts it on merge.
        if let workouts = merged["workouts"]?.arrayValue {
            merged["workouts"] = .array(workouts.sorted {
                GymWorkout(raw: $0.objectValue ?? [:]).sortKey
                    < GymWorkout(raw: $1.objectValue ?? [:]).sortKey
            })
        }

        merged["_ts"] = .int(max(local.timestamp, server.timestamp))
        // The server owns the revision; a merge result carries none.
        merged["_rev"] = nil
        // Device-local, and left exactly where this device had it. Assigning
        // nil removes the key, which is the right answer when this device has
        // no session in progress.
        merged["active"] = localRaw["active"]
        return GymState(raw: merged)
    }

    /// Union by `id`; for an id both sides have, the newer side's version wins.
    private static func unionByID(_ local: JSONValue?, _ server: JSONValue?,
                                  localNewer: Bool) -> JSONValue? {
        guard local != nil || server != nil else { return nil }
        let first = (localNewer ? server : local)?.arrayValue ?? []
        let second = (localNewer ? local : server)?.arrayValue ?? []
        var order: [String] = []
        var byID: [String: JSONValue] = [:]
        for value in first + second {
            guard let id = value.objectValue?["id"]?.stringValue else { continue }
            if byID[id] == nil { order.append(id) }
            byID[id] = value
        }
        return .array(order.compactMap { byID[$0] })
    }

    /// Union by day; for a day both sides have, the larger `t` wins.
    private static func unionBodyweight(_ local: JSONValue?,
                                        _ server: JSONValue?) -> JSONValue? {
        guard local != nil || server != nil else { return nil }
        var byDay: [String: JSONValue] = [:]
        for value in (local?.arrayValue ?? []) + (server?.arrayValue ?? []) {
            guard let object = value.objectValue,
                  let day = object["d"]?.stringValue else { continue }
            let incoming = object["t"]?.intValue ?? 0
            let existing = byDay[day]?.objectValue?["t"]?.intValue ?? Int.min
            if byDay[day] == nil || incoming > existing { byDay[day] = value }
        }
        return .array(byDay.keys.sorted().compactMap { byDay[$0] })
    }

    /// An ordered set union, newer side first.
    private static func unionFavourites(_ local: JSONValue?, _ server: JSONValue?,
                                        localNewer: Bool) -> JSONValue? {
        guard local != nil || server != nil else { return nil }
        let first = (localNewer ? local : server)?.arrayValue ?? []
        let second = (localNewer ? server : local)?.arrayValue ?? []
        var seen: Set<String> = []
        var ordered: [JSONValue] = []
        for value in first + second {
            guard let id = value.stringValue, !seen.contains(id) else { continue }
            seen.insert(id)
            ordered.append(value)
        }
        return .array(ordered)
    }

    /// Union by exercise id, keeping the LARGER `w`.
    private static func unionHeavier(_ local: JSONValue?,
                                     _ server: JSONValue?) -> JSONValue? {
        guard local != nil || server != nil else { return nil }
        var merged = server?.objectValue ?? [:]
        for (id, value) in local?.objectValue ?? [:] {
            let incoming = value.objectValue?["w"]?.doubleValue ?? -.greatestFiniteMagnitude
            let existing = merged[id]?.objectValue?["w"]?.doubleValue
                ?? -.greatestFiniteMagnitude
            if merged[id] == nil || incoming > existing { merged[id] = value }
        }
        return .object(merged)
    }

    /// A plain key union; the newer side wins a collision.
    private static func unionKeys(_ local: JSONValue?, _ server: JSONValue?,
                                  localNewer: Bool) -> JSONValue? {
        guard local != nil || server != nil else { return nil }
        var merged = (localNewer ? server : local)?.objectValue ?? [:]
        for (key, value) in (localNewer ? local : server)?.objectValue ?? [:] {
            merged[key] = value
        }
        return .object(merged)
    }
}

// MARK: - Today

/// `GET /api/gym/today`, pre-resolved by the server so the Gym screen does not
/// have to know openGym's internals.
struct GymToday: Equatable, Codable {
    var date: String
    var weekday: String
    var routine: Routine?
    var lastWorkout: GymWorkout?

    struct Routine: Equatable, Codable {
        var id: String
        /// Nil when the plan points at a routine that has been DELETED. That
        /// is not a rest day and is never drawn as one.
        var name: String?
        var exercises: [Exercise]
    }

    struct Exercise: Identifiable, Equatable, Codable {
        var id: String
        /// Falls back to the raw exercise id on the server side, so this is
        /// only nil on a payload that predates the contract.
        var name: String?
        var sets: Int?
        var reps: Int?
        var weight: Double?
        /// `reps`, `time` or `cardio` - already resolved against the
        /// catalogue, which the app has no other way to read.
        var mode: String?
        var bodyweight: Bool?
    }

    enum CodingKeys: String, CodingKey {
        case date, weekday, routine
        case lastWorkout = "last_workout_for_routine"
    }

    /// True for a rest day AND for a day with nothing planned. The two are
    /// told apart from the state document (`dayPlan[date] == "rest"`), never
    /// from this payload.
    var isRestDay: Bool { routine == nil }

    /// What the app renders when the server cannot answer but the last state
    /// is cached - and what Demo renders, since Demo has no server at all.
    ///
    /// Deliberately the same resolution order as `gym.today` on the mini:
    /// `dayPlan` override, then `"rest"`, then the week. The one thing it
    /// cannot reproduce is the built-in catalogue, so names come from the
    /// profile's own custom exercises and the name book.
    static func resolve(from state: GymState, on day: String,
                        names: GymNameBook) -> GymToday {
        let weekdayName: String
        if let date = GymClock.date(fromDay: day) {
            weekdayName = Self.weekdayNames[GymClock.jsWeekday(date)]
        } else {
            weekdayName = ""
        }
        guard let id = state.routineID(on: day), let routine = state.routine(id: id) else {
            return GymToday(date: day, weekday: weekdayName, routine: nil,
                            lastWorkout: nil)
        }
        let exercises = routine.exercises.map { config in
            Exercise(id: config.id,
                     name: names.name(for: config.id),
                     sets: config.sets,
                     reps: config.reps,
                     weight: config.weight,
                     mode: config.mode,
                     bodyweight: config.raw["bodyweight"]?.boolValue)
        }
        return GymToday(
            date: day,
            weekday: weekdayName,
            routine: Routine(id: id, name: routine.name, exercises: exercises),
            lastWorkout: state.lastWorkout(forRoutine: id))
    }

    static let weekdayNames = ["Sunday", "Monday", "Tuesday", "Wednesday",
                               "Thursday", "Friday", "Saturday"]
}

// MARK: - Names

/// Exercise ids to display names, accumulated rather than fetched.
///
/// ## Why this exists
///
/// openGym's 1324 built-in exercise names live in the container's own dataset,
/// and the ATARU server exposes NO endpoint for them (the bridge has a
/// `library` command; `app/gym.py` uses it internally for `/api/gym/today` and
/// publishes nothing). The state document carries only ids for those, so a
/// routine or a past session rendered from the state alone would read as
/// "0043" rather than "barbell squat".
///
/// What the app can do without inventing an endpoint is remember: every
/// `/api/gym/today` payload names the exercises in one routine, so opening the
/// screen on successive days fills this in, and a single pass over the week's
/// distinct routines fills it in at once. Anything still unresolved is shown
/// as its raw id, which is what the server itself falls back to - never the
/// word "Unknown", which tells a reader nothing and hides which exercise it
/// was.
struct GymNameBook: Equatable, Codable {
    private(set) var names: [String: String] = [:]

    init(names: [String: String] = [:]) { self.names = names }

    func name(for id: String) -> String { names[id] ?? id }

    /// True when nothing better than the raw id is known.
    func isUnresolved(_ id: String) -> Bool { names[id] == nil }

    /// The learned name, or nil - as opposed to `name(for:)`, which answers
    /// the id. The caller that has a second source to try (the catalogue) has
    /// to be able to tell "not known here" from "known, and it is called
    /// 0043".
    func resolvedName(for id: String) -> String? { names[id] }

    mutating func absorb(_ today: GymToday) {
        for exercise in today.routine?.exercises ?? [] {
            guard let name = exercise.name, !name.isEmpty, name != exercise.id else {
                continue
            }
            names[exercise.id] = name
        }
    }

    /// The profile's own custom exercises, which ARE in the state document.
    mutating func absorb(_ state: GymState) {
        for (id, name) in state.customExerciseNames where !name.isEmpty {
            names[id] = name
        }
    }
}

// MARK: - Transport

/// A state document and the revision it was read at.
struct GymDocument: Equatable {
    var revision: Int
    var state: GymState
}

/// The answer to a conditional write.
enum GymWriteResult: Equatable {
    /// Stored. Carries the document AS STORED, `_rev` and `_ts` set by the
    /// server, which is what the caller adopts.
    case stored(GymDocument)
    /// Someone else wrote first. Carries the document that IS current, to
    /// merge against and retry once.
    case conflict(GymDocument)
}

/// Why the gym could not answer.
///
/// Kept apart from `APIError` for one reason: neither of these may ever be
/// drawn as an empty week. "openGym is off" and "the orin is down" are claims
/// about the server, and rendering either as a rest day is a claim about
/// Arya's training that the app has no evidence for.
enum GymError: LocalizedError, Equatable {
    /// `ATARU_GYM=1` is not set on the chat server - the endpoints are not
    /// merely empty, they are not there.
    case disabled
    /// The orin, the ssh hop or the bridge could not answer.
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .disabled:
            return "openGym isn't switched on for this server."
        case .unavailable(let detail):
            return detail.isEmpty
                ? "openGym is unavailable right now."
                : "openGym is unavailable right now (\(detail))."
        }
    }
}
