import Foundation
import SwiftUI

// MARK: - Sync state

/// What the Gym screen says about its own freshness, in one word.
///
/// Five cases rather than a bool, because "the network is down", "openGym is
/// switched off" and "the orin is unreachable" are three different things and
/// exactly one of them is about this phone's connection. None of them may be
/// drawn as an empty week - see GymError.
enum GymSyncState: Equatable {
    case idle
    case syncing
    case synced(Date)
    /// Showing what was last cached, with when that was.
    case offline(Date?)
    case unavailable(String)

    var label: String {
        switch self {
        case .idle:        return ""
        case .syncing:     return "Syncing"
        case .synced:      return "Synced"
        case .offline:     return "Offline"
        case .unavailable: return "Unavailable"
        }
    }

    var tone: StatusTone {
        switch self {
        case .idle, .syncing: return .unknown
        case .synced:         return .online
        case .offline:        return .warning
        case .unavailable:    return .failure
        }
    }

    /// True while the screens must not offer a write. Everything renders;
    /// nothing saves.
    var isReadOnly: Bool {
        switch self {
        case .offline, .unavailable: return true
        default:                     return false
        }
    }
}

// MARK: - A session in progress

/// The workout being logged right now.
///
/// Device-local by design: openGym's `active` key is deleted by the server on
/// every write, so a session in progress exists on one device and nowhere
/// else. That makes persisting it here non-optional - a phone locked between
/// two sets, or switched to the timer app, must not lose the sets already
/// logged, and there is no server copy to fall back on.
struct ActiveWorkout: Codable, Equatable {
    var id: String
    var routineID: String
    var routineName: String
    /// The training day, in LOCAL components - fixed when the session starts,
    /// so a session begun at 23:50 stays on the day it was begun.
    var day: String
    var startedAt: Int
    var restSeconds: Int
    var entries: [Entry]
    /// WHEN THE REST ENDS, not how much is left.
    ///
    /// Ms epoch, stored with the session and therefore surviving the screen
    /// going away, the app being backgrounded and the phone being locked. A
    /// countdown held in a view's `@State` and decremented by a timer is none
    /// of those things: leaving the screen tore the state down, and coming
    /// back showed no rest at all - "the rest timer must survive leaving the
    /// screen or the app".
    ///
    /// An absolute instant also cannot drift. Remaining time is recomputed
    /// from the clock on every appear and every foreground, so a phone that
    /// spent four minutes in a pocket comes back to a finished rest rather
    /// than to four minutes it never counted.
    ///
    /// Optional, and old session files decode with it absent, which reads
    /// correctly as "nothing is resting".
    var restEndsAt: Int?

    struct Entry: Codable, Equatable, Identifiable {
        var id: UUID = UUID()
        var exerciseID: String
        var name: String
        /// The routine's own config for this exercise, carried into the
        /// finished session as `target` exactly as openGym does - so the log
        /// records what was planned as well as what was done.
        var target: [String: JSONValue]
        var sets: [SetEntry]

        var doneCount: Int { sets.filter(\.done).count }
    }

    struct SetEntry: Codable, Equatable, Identifiable {
        var id: UUID = UUID()
        var weight: Double
        var reps: Int
        var done: Bool = false
    }

    var doneSetCount: Int { entries.reduce(0) { $0 + $1.doneCount } }
    var totalSetCount: Int { entries.reduce(0) { $0 + $1.sets.count } }
    var hasAnythingLogged: Bool { doneSetCount > 0 }

    /// Seconds of rest still to run, from the clock rather than from a
    /// counter. Nil when nothing is resting; never negative, and a rest whose
    /// end has passed is simply over.
    func restRemaining(at now: Date = Date()) -> Int? {
        guard let restEndsAt else { return nil }
        let seconds = (Double(restEndsAt) - now.timeIntervalSince1970 * 1000) / 1000
        guard seconds > 0 else { return nil }
        return Int(seconds.rounded(.up))
    }

    /// The session as openGym writes it (`finish-workout.js`).
    ///
    /// Entries with no completed set are dropped - they are what openGym drops
    /// at finish time and they never reach the array. The rows that survive
    /// keep their own `done` flag, so a set started and not finished is
    /// recorded as exactly that rather than silently promoted.
    func finishedWorkout(endedAt: Int, bodyweight: Double?) -> GymWorkout {
        let payload = entries.compactMap { entry -> JSONValue? in
            let done = entry.sets.filter(\.done)
            guard !done.isEmpty else { return nil }
            let rows = entry.sets.map { row -> JSONValue in
                .object(["w": .number(row.weight), "r": .int(row.reps),
                         "done": .bool(row.done), "phase": .string("work")])
            }
            var object: [String: JSONValue] = [
                "id": .string(entry.exerciseID),
                "rid": .string(routineID),
                "sets": .array(rows),
                "target": .object(entry.target)
            ]
            if let top = done.map(\.weight).max() { object["topW"] = .number(top) }
            return .object(object)
        }
        var raw: [String: JSONValue] = [
            "id": .string(id),
            "d": .string(day),
            "start": .int(startedAt),
            "end": .int(endedAt),
            // The real list, plus the legacy scalar mirror of its first
            // element. Both, because openGym's own readers match on both.
            "routineIds": .array([.string(routineID)]),
            "routineId": .string(routineID),
            "name": .string(routineName),
            "entries": .array(payload),
            "prs": .array([])
        ]
        if let bodyweight { raw["bw"] = .number(bodyweight) }
        return GymWorkout(raw: raw)
    }
}

/// Where the session in progress lives between app launches.
///
/// Application Support rather than Caches: the system may evict a cache
/// whenever it likes, and the one file in this app that must not evaporate is
/// the one holding sets that have been done but not yet saved. Written with
/// complete file protection, like every other file this app puts on the phone
/// - it is health-class data, so it is unreadable while the phone is locked.
enum ActiveWorkoutStore {

    private static var fileURL: URL? {
        guard let dir = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true) else { return nil }
        let folder = dir.appending(path: "gym")
        try? FileManager.default.createDirectory(at: folder,
                                                 withIntermediateDirectories: true)
        return folder.appending(path: "active-workout.json")
    }

    static func load() -> ActiveWorkout? {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(ActiveWorkout.self, from: data)
    }

    static func save(_ workout: ActiveWorkout?) {
        guard let fileURL else { return }
        guard let workout else {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        guard let data = try? JSONEncoder().encode(workout) else { return }
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtection])
    }

    /// Part of "delete what ATARU has put on this phone", alongside the tile
    /// caches and the downloaded documents.
    static func purge() { save(nil) }
}

// MARK: - The store

/// One openGym profile, shared by every Gym page.
///
/// ## The write rule, which is the whole design
///
/// Every change is made to a copy of the WHOLE document, sent with the
/// revision it was read at, and adopted back from whatever the server stored.
/// A 409 is merged against the document the server hands back and retried
/// exactly once. What this never does is re-send its own copy with the
/// server's newer number: that is the silent overwrite the revision check
/// exists to prevent, and the thing it would delete is whatever Arya just did
/// in the browser.
@MainActor
final class GymStore: ObservableObject {

    @Published private(set) var state: GymState?
    @Published private(set) var today: GymToday?
    @Published private(set) var names = GymNameBook()
    @Published private(set) var revision = 0
    @Published private(set) var sync: GymSyncState = .idle
    @Published private(set) var cachedAt: Date?
    /// Surfaced on the page, cleared by the next successful write. Never
    /// carries a weight, a count or an exercise - see the privacy note in
    /// GymState.
    @Published var errorMessage: String?
    @Published private(set) var isSaving = false
    @Published private(set) var active: ActiveWorkout?
    /// openGym's built-in catalogue. Nil until it has been fetched or read
    /// back off disk, and nil forever on a backend with no library route -
    /// which renders as ids and placeholders, never as an empty picker.
    @Published private(set) var library: GymLibrary?

    private var service: ATARUService?
    private var cacheRoot: URL?
    private var hasRestored = false
    /// Built once per library rather than per row: 1324 rows are looked up on
    /// every exercise of every screen, and a linear scan per row is the
    /// difference between a list that scrolls and one that does not.
    private var libraryIndex: [String: GymLibraryEntry] = [:]
    private var libraryFetchedAt: Date?

    /// What the disk holds between launches: the document, its revision, and
    /// the names learned so far.
    struct Cached: Codable {
        var revision: Int
        var state: GymState
        var names: GymNameBook
    }

    static let cacheKind = "gym"
    /// A second cache file, separate from the document on purpose: the
    /// document is Arya's and changes all day, the catalogue is openGym's and
    /// changes on an upgrade. Holding them together would mean re-writing
    /// 1324 rows on every set he logs.
    static let libraryCacheKind = "gym-library"

    /// What the disk holds of the catalogue.
    struct CachedLibrary: Codable {
        var library: GymLibrary
    }

    /// How long a cached catalogue is trusted before it is fetched again.
    ///
    /// A day, per the brief, and the right order of magnitude: the server
    /// caches it for an hour and it only actually moves when openGym's dataset
    /// is upgraded. It is deliberately NOT polled with `rev`, which counts
    /// changes to Arya's own document.
    static let libraryMaxAge: TimeInterval = 24 * 60 * 60

    // MARK: Configuration

    func configure(service: ATARUService, cacheRoot: URL?) {
        self.service = service
        self.cacheRoot = cacheRoot
        if active == nil { active = ActiveWorkoutStore.load() }
    }

    // MARK: Reading

    /// Last known content in the first frame, then the network - the same
    /// shape every other tile screen uses.
    func restore() async {
        guard !hasRestored, state == nil else { return }
        hasRestored = true
        guard let cached = await TileCache.load(Cached.self, kind: Self.cacheKind,
                                                for: cacheRoot) else { return }
        state = cached.payload.state
        revision = cached.payload.revision
        names = cached.payload.names
        cachedAt = cached.savedAt
        today = GymToday.resolve(from: cached.payload.state,
                                 on: GymClock.day(), names: cached.payload.names)
    }

    /// The catalogue: disk first, then the network, and only when what is on
    /// disk is older than a day.
    ///
    /// Failure is silent by design. Every screen that uses the library already
    /// renders without it - an id where a name would be, a placeholder where
    /// an animation would be - and a banner saying the exercise catalogue
    /// could not be fetched on a page that is otherwise working is noise
    /// during a workout.
    func loadLibrary() async {
        if library == nil, let cached = await TileCache.load(
            CachedLibrary.self, kind: Self.libraryCacheKind, for: cacheRoot) {
            adopt(library: cached.payload.library, fetchedAt: cached.savedAt)
        }
        if let fetchedAt = libraryFetchedAt,
           Date().timeIntervalSince(fetchedAt) < Self.libraryMaxAge { return }
        guard let service else { return }
        guard let fetched = try? await service.gymLibrary() else { return }
        adopt(library: fetched, fetchedAt: Date())
        if let cacheRoot {
            TileCache.save(CachedLibrary(library: fetched),
                           kind: Self.libraryCacheKind, for: cacheRoot)
        }
    }

    private func adopt(library: GymLibrary, fetchedAt: Date) {
        self.library = library
        libraryIndex = library.index()
        libraryFetchedAt = fetchedAt
    }

    // MARK: Naming and media

    /// The best name this app has for an exercise id.
    ///
    /// Three sources in order, and the id itself is the honest last answer -
    /// never "Unknown", which hides WHICH exercise it was. The name book
    /// carries what the server already resolved; the catalogue answers for
    /// every built-in id whether or not the server has been asked about it.
    func displayName(for id: String) -> String {
        if let learned = names.resolvedName(for: id) { return learned }
        if let entry = libraryIndex[id] { return entry.name }
        return id
    }

    /// The same, for a caller that already holds a name from the server.
    ///
    /// `/api/gym/today` "falls back to the raw exercise id if nothing resolves
    /// it", so its `name` is never nil and a plain `??` never fires - which is
    /// how a catalogue exercise rendered as "0003" on a screen that had the
    /// catalogue open. A name equal to the id is not a name.
    func displayName(for id: String, fallback: String?) -> String {
        let resolved = displayName(for: id)
        if resolved != id { return resolved }
        if let fallback, !fallback.isEmpty, fallback != id { return fallback }
        return id
    }

    /// The catalogue row for an id, or the profile's own custom exercise
    /// dressed as one. Nil for an id neither knows, which is a real answer.
    func libraryEntry(for id: String) -> GymLibraryEntry? {
        if let entry = libraryIndex[id] { return entry }
        return state?.customLibraryEntries.first { $0.id == id }
    }

    /// The animation for an exercise, or nil - which is not a failure. A
    /// custom exercise has no media at all, and so does a catalogue row the
    /// dataset never had an animation for.
    func gifURL(forExercise id: String) -> URL? {
        guard let library, let entry = libraryIndex[id] else { return nil }
        return library.gifURL(for: entry)
    }

    /// Everything that can be added to a routine: the catalogue, plus this
    /// profile's own custom exercises.
    ///
    /// Merged here rather than server-side, because the customs live in the
    /// document this store already holds and a day-old cached copy of them
    /// would hide one Arya added two minutes ago in the browser.
    func searchableExercises(matching query: String) -> [GymLibraryEntry] {
        let customs = state?.customLibraryEntries ?? []
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let words = needle.split(separator: " ").map(String.init)
        let matchedCustoms = needle.isEmpty
            ? customs
            : customs.filter { entry in words.allSatisfy { entry.haystack.contains($0) } }
        // Customs first: they are his, there are a handful of them, and they
        // are what he is most likely to be looking for.
        return matchedCustoms + (library?.search(needle) ?? [])
    }

    func refresh() async {
        guard let service else { return }
        if state == nil { sync = .syncing }
        do {
            let document = try await service.gymState()
            adopt(document)
            // Asked for explicitly rather than left to the server's clock: the
            // phone's day is the one Arya is standing in.
            if let resolved = try? await service.gymToday(date: GymClock.day()) {
                today = resolved
                names.absorb(resolved)
            } else {
                today = GymToday.resolve(from: document.state, on: GymClock.day(),
                                         names: names)
            }
            cachedAt = nil
            sync = .synced(Date())
            save()
            await fillNames()
        } catch let error as GymError {
            // The feature is off, or the orin is unreachable. Both keep
            // whatever is on screen and neither is drawn as a rest day.
            sync = .unavailable(error.errorDescription ?? "openGym is unavailable.")
        } catch {
            guard !TileFetchError.isCancellation(error) else { return }
            sync = .offline(cachedAt)
            if today == nil, let state {
                today = GymToday.resolve(from: state, on: GymClock.day(), names: names)
            }
        }
    }

    /// The cheap poll. One request, no document, and the state is fetched only
    /// when the number has actually moved - which is what makes running this
    /// on every foreground reasonable.
    func refreshIfChanged() async {
        guard let service, state != nil else {
            await refresh()
            return
        }
        do {
            let remote = try await service.gymRevision()
            if remote != revision { await refresh() } else { sync = .synced(Date()) }
        } catch let error as GymError {
            sync = .unavailable(error.errorDescription ?? "openGym is unavailable.")
        } catch {
            guard !TileFetchError.isCancellation(error) else { return }
            sync = .offline(cachedAt)
        }
    }

    // MARK: Writing

    /// Applies a change to the whole document and saves it.
    ///
    /// Returns false when nothing was stored, and in that case the caller's
    /// own state is deliberately left alone - a finished workout that failed
    /// to upload stays in the session file rather than disappearing.
    @discardableResult
    func commit(_ change: (inout GymState) -> Void) async -> Bool {
        guard let service, var local = state else {
            errorMessage = "Nothing to save against yet - pull to refresh first."
            return false
        }
        change(&local)
        // Marks this side as the one that changed, which is what the merge
        // rule reads. The server overwrites `_ts` regardless.
        local.touch()

        isSaving = true
        defer { isSaving = false }
        do {
            switch try await service.gymWrite(state: local, baseRev: revision) {
            case .stored(let document):
                adopt(document)
                sync = .synced(Date())
                errorMessage = nil
                save()
                return true
            case .conflict(let current):
                // Someone wrote while this was in flight. Merge openGym's own
                // way and try once more against the revision it just named.
                let merged = GymMerge.merge(local: local, server: current.state)
                switch try await service.gymWrite(state: merged,
                                                  baseRev: current.revision) {
                case .stored(let document):
                    adopt(document)
                    sync = .synced(Date())
                    errorMessage = nil
                    save()
                    return true
                case .conflict(let again):
                    // Twice in a row means something else is writing steadily.
                    // Adopt what is current and say so, rather than pushing a
                    // third time over a document that keeps moving.
                    adopt(again)
                    save()
                    errorMessage = "Another device was writing. Nothing was saved - try again."
                    return false
                }
            }
        } catch let error as GymError {
            sync = .unavailable(error.errorDescription ?? "openGym is unavailable.")
            errorMessage = error.errorDescription
            return false
        } catch {
            guard !TileFetchError.isCancellation(error) else { return false }
            errorMessage = "Couldn't save - no answer from the server."
            sync = .offline(cachedAt)
            return false
        }
    }

    @discardableResult
    func recordBodyweight(_ weight: Double) async -> Bool {
        await commit { $0.recordBodyweight(weight, on: GymClock.day()) }
    }

    @discardableResult
    func save(routine: GymRoutine) async -> Bool {
        await commit { $0.replaceRoutine(routine) }
    }

    /// Adds an exercise to a routine as a CUSTOM one.
    ///
    /// The built-in library is not reachable from this app - see GymNameBook -
    /// so an exercise added here is added to the profile's own catalogue with
    /// the name Arya typed. That is a real openGym custom exercise, not a
    /// placeholder, and the web app treats it as one.
    @discardableResult
    func addExercise(named name: String, to routineID: String) async -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let id = "c" + GymClock.uid()
        let stored = await commit { state in
            state.addCustomExercise(id: id, name: trimmed)
            guard var routine = state.routine(id: routineID) else { return }
            var list = routine.exercises
            list.append(GymExerciseConfig(raw: ["id": .string(id), "sets": .int(3),
                                                "reps": .int(10),
                                                "weight": .number(0)]))
            routine.setExercises(list)
            state.replaceRoutine(routine)
        }
        if stored, let state { names.absorb(state) }
        return stored
    }

    /// Adds a CATALOGUE exercise to a routine.
    ///
    /// The difference from `addExercise(named:)` is the whole point of the
    /// picker: this writes openGym's own id (`"0043"`) into `routine.ex` and
    /// adds NOTHING to `customEx`. That is exactly what the web app writes
    /// when the same exercise is picked there, so the entry resolves to the
    /// catalogue's name, body part and animation on every client rather than
    /// becoming a second private copy of an exercise openGym already has.
    ///
    /// The config is the same 3 x 10 openGym defaults a new entry to, at zero
    /// weight, and every other key is left ABSENT - `sets`, `mode`, `reps` and
    /// `weight` are the only ones openGym writes unconditionally, and
    /// inventing values for the rest is how a client writes a document the web
    /// app then reads differently.
    @discardableResult
    func addLibraryExercise(_ entry: GymLibraryEntry, to routineID: String) async -> Bool {
        // A custom exercise reaching this path would silently lose its
        // customEx row; it has its own method and its own id namespace.
        guard !entry.id.isEmpty else { return false }
        return await commit { state in
            guard var routine = state.routine(id: routineID) else { return }
            var list = routine.exercises
            list.append(GymExerciseConfig(raw: ["id": .string(entry.id),
                                                "sets": .int(3),
                                                "reps": .int(10),
                                                "weight": .number(0)]))
            routine.setExercises(list)
            state.replaceRoutine(routine)
        }
    }

    // MARK: A session

    func startWorkout() {
        guard let today, let routine = today.routine, let state else { return }
        let configs = state.routine(id: routine.id)?.exercises ?? []
        let entries = routine.exercises.map { exercise -> ActiveWorkout.Entry in
            let config = configs.first { $0.id == exercise.id }
            let planned = max(1, exercise.sets ?? config?.sets ?? 1)
            // Prefilled from the last time this exercise was actually done,
            // and only then from the routine's own defaults. The routine's
            // number is what was planned; the last session is what happened.
            let last = state.lastEntry(forExercise: exercise.id)
            let lastSets = last?.doneSets ?? []
            let fallbackWeight = exercise.weight
                ?? config?.weight
                ?? state.rememberedWeight(forExercise: exercise.id)
                ?? 0
            let fallbackReps = exercise.reps ?? config?.reps ?? 10
            let rows = (0..<planned).map { index -> ActiveWorkout.SetEntry in
                let source = index < lastSets.count ? lastSets[index] : lastSets.last
                return ActiveWorkout.SetEntry(
                    weight: source?.weight ?? fallbackWeight,
                    reps: source?.reps ?? fallbackReps,
                    done: false)
            }
            return ActiveWorkout.Entry(
                exerciseID: exercise.id,
                name: displayName(for: exercise.id, fallback: exercise.name),
                target: config?.raw ?? ["id": .string(exercise.id),
                                        "sets": .int(planned)],
                sets: rows)
        }
        setActive(ActiveWorkout(
            id: GymClock.uid(),
            routineID: routine.id,
            routineName: routine.name ?? "Workout",
            day: GymClock.day(),
            startedAt: GymClock.milliseconds(),
            restSeconds: state.restSeconds,
            entries: entries))
    }

    /// Persisted on every change, not on a timer: the events this has to
    /// survive - a lock, an app switch, a crash - give no warning.
    func setActive(_ workout: ActiveWorkout?) {
        active = workout
        ActiveWorkoutStore.save(workout)
    }

    /// Edits the session in place.
    ///
    /// `persist: false` is for a keystroke: the value is live in memory and on
    /// screen, and the disk write happens at the next moment that actually
    /// matters (a set marked done, a set added, the app leaving the
    /// foreground). A file rewritten per character would be the only thing in
    /// this app doing that.
    func updateActive(persist: Bool = true, _ change: (inout ActiveWorkout) -> Void) {
        guard var workout = active else { return }
        change(&workout)
        active = workout
        if persist { ActiveWorkoutStore.save(workout) }
    }

    /// Flushes whatever is in memory. Called before the app leaves the
    /// foreground and when the session screen goes away.
    func persistActive() { ActiveWorkoutStore.save(active) }

    /// Throws the session away for good: the file on the phone goes, and
    /// nothing is sent anywhere.
    ///
    /// openGym is never told, because it was never told the session existed -
    /// `active` is device-local and the server deletes the key on every write.
    /// So a discard is purely local and there is nothing to undo it with,
    /// which is why every caller asks first.
    ///
    /// "He started Ayush C, backed out, and now sees Resume workout with no
    /// way to abandon it": backing out of the session screen leaves the file
    /// in place by design, and until this there was no control anywhere that
    /// removed it.
    func discardWorkout() {
        GymRestNotice.cancel()
        setActive(nil)
    }

    // MARK: Rest

    /// Starts a rest from now, as an ABSOLUTE end time, and books the notice.
    ///
    /// Stored on the session rather than in a view, so leaving the screen or
    /// the app does not end it - see `ActiveWorkout.restEndsAt`. Persisted
    /// immediately for the same reason: the event it has to survive is the app
    /// being suspended, which gives no warning.
    func startRest(seconds: Int? = nil) {
        guard let workout = active else { return }
        let length = max(10, seconds ?? workout.restSeconds)
        let end = Date().addingTimeInterval(TimeInterval(length))
        updateActive { $0.restEndsAt = GymClock.milliseconds(end) }
        Task { await GymRestNotice.schedule(at: end) }
    }

    /// Skipped, or superseded by the next set. Clears the bar and the pending
    /// notice together - a "Rest over" arriving after he has already started
    /// the next set is worse than none.
    func stopRest() {
        GymRestNotice.cancel()
        guard active?.restEndsAt != nil else { return }
        updateActive { $0.restEndsAt = nil }
    }

    /// Drops a rest whose end has already passed, so the session file does not
    /// carry a stale instant around. Called on appear and on foreground, where
    /// the answer is recomputed from the clock anyway.
    func reconcileRest(at now: Date = Date()) {
        guard let workout = active, workout.restEndsAt != nil,
              workout.restRemaining(at: now) == nil else { return }
        updateActive { $0.restEndsAt = nil }
        GymRestNotice.cancel()
    }

    /// Writes the session and, only on success, clears it from the phone.
    @discardableResult
    func finishWorkout() async -> Bool {
        guard let active else { return false }
        guard active.hasAnythingLogged else {
            discardWorkout()
            return true
        }
        // The weigh-in, when there is one for the session's day.
        let bodyweight = state?.bodyweight.first { $0.day == active.day }?.weight
        let workout = active.finishedWorkout(endedAt: GymClock.milliseconds(),
                                             bodyweight: bodyweight)
        let stored = await commit { $0.appendWorkout(workout) }
        // A failed save KEEPS the session. There is no server copy of it, so
        // clearing it here would be the one place this app can lose data.
        if stored { discardWorkout() }
        return stored
    }

    // MARK: Plumbing

    private func adopt(_ document: GymDocument) {
        state = document.state
        revision = document.revision
        names.absorb(document.state)
        cachedAt = nil
        // Today is resolved from the document, so a write that changes the
        // document changes it too - a session finished at the rack has to move
        // "last trained" without waiting for a round trip nobody asked for.
        // Locally rather than from the server: the names are already in the
        // book by this point, and the resolution order is the same one.
        if today != nil {
            today = GymToday.resolve(from: document.state, on: GymClock.day(),
                                     names: names)
        }
    }

    private func save() {
        guard let cacheRoot, let state else { return }
        TileCache.save(Cached(revision: revision, state: state, names: names),
                       kind: Self.cacheKind, for: cacheRoot)
    }

    /// Learns the names of exercises the document only carries ids for.
    ///
    /// One request per distinct routine in the coming week, and only when that
    /// routine still has an unresolved exercise - so it costs nothing on the
    /// second open and nothing at all for a profile of custom exercises. See
    /// GymNameBook for why there is no library call to make instead.
    private func fillNames() async {
        guard let service, let state else { return }
        var wanted: [String: String] = [:]
        for offset in 0..<7 {
            guard let date = Calendar.current.date(byAdding: .day, value: offset,
                                                   to: Date()) else { continue }
            let day = GymClock.day(date)
            guard let id = state.routineID(on: day), wanted[id] == nil,
                  let routine = state.routine(id: id),
                  routine.exercises.contains(where: { names.isUnresolved($0.id) })
            else { continue }
            wanted[id] = day
        }
        guard !wanted.isEmpty else { return }
        for day in wanted.values.sorted() {
            guard let payload = try? await service.gymToday(date: day) else { continue }
            names.absorb(payload)
        }
        save()
    }
}
