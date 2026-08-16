import XCTest
@testable import ATARU

/// The claims this app makes about its own data, written down where a change
/// has to get past them.
///
/// Every case below is a fix for something that was on screen or on the wire
/// and was not true: a control that reported a state the server had not
/// agreed to, a failure reported as a different failure, or a user's own edit
/// quietly thrown away.
final class DataTruthfulnessTests: XCTestCase {

    // MARK: - A cancelled request is not an unreachable server

    /// `URLError.cancelled` is what URLSession raises when a newer tap
    /// replaces an in-flight request, which the tile screens do by design on
    /// every rapid re-tap. It was classified `.unreachable`, so stepping a
    /// thermostat quickly printed "no answer from the server" on a page whose
    /// requests were all landing.
    func testACancelledRequestIsNotReportedAsAnUnreachableServer() {
        let cancelled = NSError(domain: NSURLErrorDomain,
                                code: NSURLErrorCancelled, userInfo: nil)
        XCTAssertEqual(TileFetchError.from(cancelled, timeout: 10), .cancelled)
        XCTAssertNotEqual(TileFetchError.from(cancelled, timeout: 10), .unreachable)
    }

    func testCancellationIsRecognisedInEveryFormItArrivesIn() {
        let urlError = NSError(domain: NSURLErrorDomain,
                               code: NSURLErrorCancelled, userInfo: nil)
        XCTAssertTrue(TileFetchError.isCancellation(urlError))
        XCTAssertTrue(TileFetchError.isCancellation(CancellationError()))
        XCTAssertTrue(TileFetchError.isCancellation(TileFetchError.cancelled))
    }

    /// The direction that matters: a real network fault must still be one.
    func testGenuineFailuresAreStillClassifiedAsBefore() {
        let timedOut = NSError(domain: NSURLErrorDomain,
                               code: NSURLErrorTimedOut, userInfo: nil)
        let noRoute = NSError(domain: NSURLErrorDomain,
                              code: NSURLErrorCannotConnectToHost, userInfo: nil)
        XCTAssertEqual(TileFetchError.from(timedOut, timeout: 25), .timedOut(seconds: 25))
        XCTAssertEqual(TileFetchError.from(noRoute, timeout: 10), .unreachable)
        XCTAssertEqual(TileFetchError.from(TileFetchError.status(502), timeout: 10),
                       .status(502))
        XCTAssertFalse(TileFetchError.isCancellation(noRoute))
        XCTAssertFalse(TileFetchError.isCancellation(TileFetchError.undecodable))
    }

    /// Nothing to say, so nothing is said. Every other case carries a line
    /// because every other case is worth telling someone about.
    func testACancelledRequestHasNoMessageToShow() {
        XCTAssertNil(TileFetchError.cancelled.errorDescription)
        XCTAssertEqual(TileFetchError.cancelled.refreshNote, "")
        XCTAssertNotNil(TileFetchError.unreachable.errorDescription)
    }

    // MARK: - A parse does not clear the boxes the user ticked

    func testAdoptingAParseKeepsTickedRowsTicked() {
        let seeded = [NoteTask(title: "Call the landlord", isDone: true),
                      NoteTask(title: "Book the dentist")]
        let parsed = [NoteTask(title: "Call the landlord", category: "Personal"),
                      NoteTask(title: "Book the dentist", category: "Health")]

        let merged = NoteTask.merge(parsed: parsed, into: seeded)

        XCTAssertEqual(merged.count, 2)
        XCTAssertTrue(merged[0].isDone, "a ticked row came back unticked")
        XCTAssertEqual(merged[0].id, seeded[0].id, "the row lost its identity")
        XCTAssertFalse(merged[1].isDone)
        // The server still owns everything except the checkbox.
        XCTAssertEqual(merged[1].category, "Health")
    }

    func testMatchingIgnoresCaseAndTrailingPunctuation() {
        let seeded = [NoteTask(title: "call the bank.", isDone: true)]
        let merged = NoteTask.merge(parsed: [NoteTask(title: "Call the bank")],
                                    into: seeded)
        XCTAssertTrue(merged[0].isDone)
    }

    func testRowsTheParseInventedAreNewAndUnticked() {
        let seeded = [NoteTask(title: "Call the landlord", isDone: true)]
        let merged = NoteTask.merge(
            parsed: [NoteTask(title: "Call the landlord"),
                     NoteTask(title: "Order a new boiler part")],
            into: seeded)
        XCTAssertTrue(merged[0].isDone)
        XCTAssertFalse(merged[1].isDone)
        XCTAssertNotEqual(merged[1].id, seeded[0].id)
    }

    /// One existing row cannot lend its ticked state to two parsed rows.
    func testOneRowIsClaimedOnce() {
        let seeded = [NoteTask(title: "Email Sam", isDone: true)]
        let merged = NoteTask.merge(
            parsed: [NoteTask(title: "Email Sam"), NoteTask(title: "email sam")],
            into: seeded)
        XCTAssertTrue(merged[0].isDone)
        XCTAssertFalse(merged[1].isDone, "one ticked row was counted twice")
        XCTAssertNotEqual(merged[0].id, merged[1].id)
    }

    // MARK: - Saving in Settings rebuilds the service once

    /// Setting the token and then the address rebuilt twice, and the FIRST
    /// rebuild paired the new token with the old base URL - which is where it
    /// then registered push. The generation count is the observable half of
    /// that: it is what every `.task(id:)` in the app keys on, so two bumps
    /// also meant every screen loaded twice on one tap of Save.
    @MainActor
    func testSavingAnAddressAndATokenRebuildsTheServiceOnce() {
        let state = AppState(defaults: throwawayDefaults(),
                             tokenStore: InMemoryTokenStore())
        var configuration = state.configuration
        configuration.baseURLString = "https://example-one.ts.net"
        state.apply(configuration: configuration, token: "first")

        let afterFirstSave = state.serviceGeneration

        configuration.baseURLString = "https://example-two.ts.net"
        state.apply(configuration: configuration, token: "second")

        XCTAssertEqual(state.serviceGeneration - afterFirstSave, 1,
                       "one save rebuilt the service more than once")
        XCTAssertEqual(state.token, "second")
        XCTAssertEqual(state.configuration.baseURLString, "https://example-two.ts.net")
    }

    /// A token change on its own is still one rebuild.
    @MainActor
    func testChangingOnlyTheTokenIsStillOneRebuild() {
        let state = AppState(defaults: throwawayDefaults(),
                             tokenStore: InMemoryTokenStore())
        var configuration = state.configuration
        configuration.baseURLString = "https://example.ts.net"
        state.apply(configuration: configuration, token: "one")
        let before = state.serviceGeneration
        state.apply(configuration: configuration, token: "two")
        XCTAssertEqual(state.serviceGeneration - before, 1)
        XCTAssertEqual(state.token, "two")
    }

    private func throwawayDefaults() -> UserDefaults {
        let name = "ataru.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    // MARK: - Notes on disk

    /// An unreadable file must not read as "no notes yet", and the next write
    /// must not overwrite it.
    @MainActor
    func testACorruptNotesFileIsReportedAndNotOverwritten() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "notes.json")
        let garbage = Data("this is not json".utf8)
        try garbage.write(to: file)

        let store = NoteStore(fileURL: file)
        XCTAssertTrue(store.notes.isEmpty)
        XCTAssertNotNil(store.failure, "an unreadable file read as an empty list")

        // Writing moves the unreadable file aside rather than destroying it.
        store.add(Note(transcript: "call the landlord about the boiler on friday"))
        let survivors = try FileManager.default
            .contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("notes-unreadable-") }
        XCTAssertEqual(survivors.count, 1, "the unreadable file was overwritten")
        XCTAssertNil(store.failure)
        XCTAssertEqual(store.notes.count, 1)
    }

    @MainActor
    func testAFirstLaunchWithNoFileIsNotAFailure() {
        let file = FileManager.default.temporaryDirectory
            .appending(path: "\(UUID().uuidString)/notes.json")
        let store = NoteStore(fileURL: file)
        XCTAssertTrue(store.notes.isEmpty)
        XCTAssertNil(store.failure, "an empty library was reported as a problem")
    }
}
