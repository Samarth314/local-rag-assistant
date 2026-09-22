import Foundation
import SwiftUI
import UIKit

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

    /// True when this session is being RECORDED rather than performed - a
    /// workout Arya did and is typing in afterwards.
    ///
    /// It rides on the same struct as a live session so that a past workout
    /// and a finished one are built by one piece of code and land in the
    /// document in one shape. A second builder for "the same thing, typed in
    /// later" is a second shape nobody notices has drifted.
    ///
    /// OPTIONAL rather than a defaulted `Bool`, and that is not a style
    /// choice: Swift's synthesized decoder ignores a property's default and
    /// requires every non-optional key, so a `Bool = false` here would make
    /// every session file written before this field existed fail to decode -
    /// and the file it would fail on is a workout in progress, which this
    /// phone holds the only copy of. `restEndsAt` above is optional for the
    /// same reason.
    var loggedLater: Bool?

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
        // Only when true - openGym's own convention for an optional flag, and
        // what keeps a session logged at the rack byte-for-byte the shape it
        // has always been. See `GymWorkout.isLoggedLater`.
        if loggedLater == true { raw["loggedLater"] = .bool(true) }
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
        prefetchMedia()
    }

    // MARK: Units and the rotation

    /// The unit the DOCUMENT's numbers are in, which is whatever openGym's
    /// settings last left it at.
    ///
    /// No screen ever renders this. They render `GymUnits.display` - pounds -
    /// and pass this to the conversion, so the app says lb even on a profile
    /// somebody switched back to kg in the browser.
    var documentUnit: String { state?.unit ?? GymUnits.display }

    /// The routine to do next: the one after whatever was finished last. See
    /// `GymState.nextRoutineID` for why this follows completion and not the
    /// calendar.
    var nextRoutineID: String? { state?.nextRoutineID }

    var nextRoutine: GymRoutine? {
        guard let id = nextRoutineID else { return nil }
        return state?.routine(id: id)
    }

    /// True when the CALENDAR has nothing planned for a day. A marker on the
    /// card, never a gate - the rest day is a note and the button still works.
    func isPlannedRest(on day: String = GymClock.day()) -> Bool {
        guard let state else { return false }
        return state.routineID(on: day) == nil
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
    ///
    /// A custom the CATALOGUE also answers for is dropped from the custom half
    /// and kept from the catalogue's. The bridge's `exercises-extra.json`
    /// overlay gives a handful of custom ids the animation of the dataset row
    /// for the same movement under another name - so those ids are now in both
    /// lists, with the same name and the same body part, and only one of the
    /// two carries a GIF. Concatenating them showed the exercise twice in the
    /// picker, once with the animation and once without.
    func searchableExercises(matching query: String) -> [GymLibraryEntry] {
        let customs = (state?.customLibraryEntries ?? [])
            .filter { libraryIndex[$0.id] == nil }
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

    /// The weigh-in, typed in POUNDS and stored in the document's own unit.
    ///
    /// Converted here rather than in the view for the same reason the read
    /// direction lives in `GymFormat`: one place, so a screen cannot convert
    /// twice and a new screen cannot forget.
    @discardableResult
    func recordBodyweight(pounds: Double) async -> Bool {
        let stored = GymUnits.fromDisplay(pounds, storedIn: documentUnit) ?? pounds
        return await commit { $0.recordBodyweight(stored, on: GymClock.day()) }
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
        let stored = await commit { state in
            guard var routine = state.routine(id: routineID) else { return }
            var list = routine.exercises
            list.append(GymExerciseConfig(raw: ["id": .string(entry.id),
                                                "sets": .int(3),
                                                "reps": .int(10),
                                                "weight": .number(0)]))
            routine.setExercises(list)
            state.replaceRoutine(routine)
        }
        // The general sweep in `adopt(_:)` already covers this exercise, but
        // not before the routine detail row it was just added to draws it -
        // this is what makes that first draw a disk hit rather than a fetch.
        if stored { prefetchMedia(forExercise: entry.id) }
        return stored
    }

    // MARK: A session

    /// Starts whatever is next up - what the primary button on the Today card
    /// does.
    func startWorkout() {
        guard let id = nextRoutineID else { return }
        startWorkout(routineID: id)
    }

    /// Starts a session for ANY routine, on any day, including a rest day.
    ///
    /// ## Why this is built from the document and not from `/api/gym/today`
    ///
    /// It used to read `today.routine`, which names exactly one routine: the
    /// one the CALENDAR planned for today. That is why there was no way to
    /// start anything on a Sunday and no way to pick a different routine on a
    /// Monday - the only routine the screen had in hand was the planned one,
    /// and on a rest day there wasn't even that.
    ///
    /// The state document has all three routines and every past session, so
    /// one code path now serves the next-up button, the "different routine"
    /// picker and a rest day alike. The `today` payload is still fetched: it
    /// is what teaches the name book openGym's catalogue names (see
    /// `GymNameBook`), and it still answers "what does the calendar say".
    /// It is no longer what decides whether anything can be started.
    func startWorkout(routineID: String) {
        guard let state, let routine = state.routine(id: routineID) else { return }
        setActive(buildSession(routine: routine, in: state, on: GymClock.day(),
                               startedAt: GymClock.milliseconds()))
        prefetchMedia(forRoutine: routineID)
    }

    /// One session builder, for a workout about to be done and for one being
    /// typed in afterwards.
    ///
    /// `weights` is in POUNDS and keyed by exercise id - the past-workout form
    /// is the only caller that passes any. A live session prefills from the
    /// last time the exercise was actually done instead, which is what
    /// `weights == nil` means.
    private func buildSession(routine: GymRoutine, in state: GymState,
                              on day: String, startedAt: Int,
                              weights: [String: Double]? = nil,
                              markDone: Bool = false,
                              loggedLater: Bool = false) -> ActiveWorkout {
        let entries = routine.exercises.map { config -> ActiveWorkout.Entry in
            let planned = max(1, config.sets)
            let fallbackReps = config.reps ?? 10
            let rows: [ActiveWorkout.SetEntry]
            if let weights {
                // Recorded after the fact: every set of an exercise carries
                // the one weight he remembers for it, and a blank stays blank.
                // Zero is openGym's own spelling for a set with no external
                // load, so nothing is invented by leaving it there.
                let typed = weights[config.id]
                let stored = typed.flatMap {
                    GymUnits.fromDisplay($0, storedIn: state.unit)
                } ?? 0
                rows = (0..<planned).map { _ in
                    ActiveWorkout.SetEntry(weight: stored, reps: fallbackReps,
                                           done: markDone)
                }
            } else {
                // Prefilled from the last time this exercise was actually
                // done, and only then from the routine's own defaults. The
                // routine's number is what was planned; the last session is
                // what happened.
                let last = state.lastEntry(forExercise: config.id)
                let lastSets = last?.doneSets ?? []
                let fallbackWeight = config.weight
                    ?? state.rememberedWeight(forExercise: config.id)
                    ?? 0
                rows = (0..<planned).map { index -> ActiveWorkout.SetEntry in
                    let source = index < lastSets.count ? lastSets[index] : lastSets.last
                    return ActiveWorkout.SetEntry(
                        weight: source?.weight ?? fallbackWeight,
                        reps: source?.reps ?? fallbackReps,
                        done: markDone)
                }
            }
            return ActiveWorkout.Entry(
                exerciseID: config.id,
                name: displayName(for: config.id),
                target: config.raw,
                sets: rows)
        }
        return ActiveWorkout(
            id: GymClock.uid(),
            routineID: routine.id,
            routineName: routine.name.isEmpty ? "Workout" : routine.name,
            day: day,
            startedAt: startedAt,
            restSeconds: state.restSeconds,
            entries: entries,
            // nil rather than false when it is a live session, so the file on
            // the phone stays the shape it has always been.
            loggedLater: loggedLater ? true : nil)
    }

    /// Records a workout Arya already did, on the day he did it.
    ///
    /// Written through the SAME builder and the same `finishedWorkout` as a
    /// session logged at the rack, so the only differences in the document are
    /// the day, the start time and the `loggedLater` flag. Nothing touches
    /// `active`, so a session in progress on this phone is untouched by
    /// filling this in.
    ///
    /// `weights` is in pounds, keyed by exercise id, and may be empty - a
    /// workout he remembers doing but not the numbers for is still worth more
    /// in the log than nothing, and it is what puts the rotation right.
    @discardableResult
    func logPastWorkout(routineID: String, on day: String,
                        weights: [String: Double] = [:]) async -> Bool {
        guard let state, let routine = state.routine(id: routineID) else { return false }
        // Midday, in the phone's own zone. A placeholder either way, so it is
        // one no reader can mistake for a recorded time, and one that cannot
        // slide onto the neighbouring day.
        let startedAt = GymClock.middayMilliseconds(onDay: day)
            ?? GymClock.milliseconds()
        let session = buildSession(routine: routine, in: state, on: day,
                                   startedAt: startedAt, weights: weights,
                                   markDone: true, loggedLater: true)
        // The weigh-in for THAT day, if there is one - not today's.
        let bodyweight = state.bodyweight.first { $0.day == day }?.weight
        // `end` equals `start`: how long it took is not something this form
        // asked for, and a made-up hour in a training log is worse than no
        // duration at all. Every reader already treats `end <= start` as
        // "no duration".
        let workout = session.finishedWorkout(endedAt: startedAt,
                                              bodyweight: bodyweight)
        return await commit { $0.insertWorkout(workout) }
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
        let stored = await commit { $0.insertWorkout(workout) }
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
        prefetchMedia()
    }

    // MARK: Media

    /// Warms the on-disk GIF cache for the working set - every exercise in
    /// every routine, plus the last month of history - whenever the document
    /// or the catalogue moves under it. See `GymMediaPrefetch.targetURLs` for
    /// what "working set" means and why it is never the rest of the 1,324.
    ///
    /// Only while ATARU is the thing actually on screen: this store is driven
    /// entirely from the Gym tile's own `.task`s today, so this guard is
    /// belt-and-braces against a future caller (a widget, a background
    /// refresh) firing a fetch nobody at the gym is waiting on.
    private func prefetchMedia() {
        guard UIApplication.shared.applicationState == .active else { return }
        let urls = GymMediaPrefetch.targetURLs(state: state, library: library)
        guard !urls.isEmpty else { return }
        Task.detached(priority: .background) {
            await GymMediaCache.shared.prefetch(urls)
        }
    }

    /// The same, narrowed to one routine's own exercises - fired the moment a
    /// session on it starts, so what `ActiveWorkoutView` is about to show
    /// does not wait on the broader sweep above to get to it first. A no-op
    /// for anything the broader sweep already reached.
    private func prefetchMedia(forRoutine routineID: String) {
        guard UIApplication.shared.applicationState == .active else { return }
        guard let library, let routine = state?.routine(id: routineID) else { return }
        let index = library.index()
        let urls = Set(routine.exercises.compactMap { config in
            index[config.id].flatMap(library.gifURL(for:))
        })
        guard !urls.isEmpty else { return }
        Task.detached(priority: .utility) {
            await GymMediaCache.shared.prefetch(urls)
        }
    }

    /// One exercise's animation, fetched the moment it is added to a routine
    /// - so the picker's own thumbnail (already on screen) and the routine
    /// detail row it is about to appear in are both warm before either draws
    /// it again.
    private func prefetchMedia(forExercise id: String) {
        guard UIApplication.shared.applicationState == .active else { return }
        guard let library, let entry = library.index()[id],
              let url = library.gifURL(for: entry) else { return }
        Task.detached(priority: .utility) {
            await GymMediaCache.shared.prefetch([url])
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
