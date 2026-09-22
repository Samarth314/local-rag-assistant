import XCTest
@testable import ATARU

/// `GymMediaCache` is what makes exercise animations survive a weak or
/// absent signal at the gym: disk first, then the network, a fetch written to
/// disk before it is handed back, and concurrent askers for the same filename
/// sharing one request. These tests exercise that contract directly, against
/// a temp directory and a stubbed `URLSession` rather than the real media
/// host - see `GymMediaStubProtocol` below.
///
/// `GymMediaPrefetchTests` covers the OTHER half: what belongs in the working
/// set this cache is kept warm for, which is a pure function over a state and
/// a library and has nothing to do with the network or disk at all.
final class GymMediaCacheTests: XCTestCase {

    // MARK: - Fixtures

    /// The smallest byte string ImageIO will decode as a GIF: a 1x1
    /// transparent pixel. `GymGIF.animatedImage(from:)` only needs a source
    /// with at least one frame, so this is enough to exercise every path
    /// without shipping a real exercise animation into the test bundle.
    private static let pixelGIF = Data(base64Encoded:
        "R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw==")!

    private func makeTempRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GymMediaCacheTests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func stubbedSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GymMediaStubProtocol.self]
        return URLSession(configuration: configuration)
    }

    // MARK: - Hit, miss, write

    /// A file already on disk answers `quickImage` without the network being
    /// asked at all - what lets a view draw it on the same frame, with no
    /// spinner.
    func testADiskHitReadsWithoutTouchingTheNetwork() async throws {
        let root = makeTempRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = URL(string: "https://gym.example/gif/0043-hit1234.gif")!
        try Self.pixelGIF.write(to: root.appendingPathComponent(url.lastPathComponent))

        let cache = GymMediaCache(root: root, session: stubbedSession())
        GymMediaStubProtocol.reset()
        let image = await cache.quickImage(for: url)

        XCTAssertNotNil(image)
        XCTAssertEqual(GymMediaStubProtocol.requestCount, 0,
                       "a disk hit must never reach the network")
    }

    /// Nothing on disk and nothing in memory is a real, quiet miss - not an
    /// error, and `quickImage` never fetches to answer it.
    func testAColdCacheIsAQuickMiss() async {
        let root = makeTempRoot()
        let cache = GymMediaCache(root: root, session: stubbedSession())
        let url = URL(string: "https://gym.example/gif/0043-miss123.gif")!

        let image = await cache.quickImage(for: url)

        XCTAssertNil(image)
        XCTAssertEqual(GymMediaStubProtocol.requestCount, 0)
    }

    /// A fetch is written to disk before it is handed back, under the
    /// server's own filename - so the very next call, from any view or after
    /// a relaunch, is a disk hit.
    func testAFetchIsWrittenToDiskUnderTheServerFilename() async throws {
        let root = makeTempRoot()
        let cache = GymMediaCache(root: root, session: stubbedSession())
        let url = URL(string: "https://gym.example/gif/0043-abcd123.gif")!
        GymMediaStubProtocol.reset()

        let fetched = await cache.image(for: url)
        XCTAssertNotNil(fetched)

        let onDisk = try Data(contentsOf: root.appendingPathComponent("0043-abcd123.gif"))
        XCTAssertEqual(onDisk, Self.pixelGIF)

        // And a SECOND cache instance - so nothing survives in memory - reads
        // it straight off disk with no fetch at all.
        let reopened = GymMediaCache(root: root, session: stubbedSession())
        let requestsBefore = GymMediaStubProtocol.requestCount
        let again = await reopened.quickImage(for: url)
        XCTAssertNotNil(again)
        XCTAssertEqual(GymMediaStubProtocol.requestCount, requestsBefore)
    }

    // MARK: - Coalescing

    /// Two views asking for the same animation at the same moment - the
    /// ordinary shape of a routine detail page opening - must cost one
    /// request, not two.
    func testConcurrentLoadsForTheSameFileCoalesceIntoOneFetch() async {
        let root = makeTempRoot()
        let cache = GymMediaCache(root: root, session: stubbedSession())
        let url = URL(string: "https://gym.example/gif/0043-coal9990.gif")!
        GymMediaStubProtocol.reset()
        GymMediaStubProtocol.responseDelay = 0.05

        async let first = cache.image(for: url)
        async let second = cache.image(for: url)
        let (imageA, imageB) = await (first, second)

        XCTAssertNotNil(imageA)
        XCTAssertNotNil(imageB)
        XCTAssertEqual(GymMediaStubProtocol.requestCount, 1,
                       "two concurrent askers for one filename issued \(GymMediaStubProtocol.requestCount) requests")
    }

    // MARK: - A purged directory

    /// iOS may empty Caches at any moment. A cache instance that starts with
    /// nothing in memory and finds nothing on disk must answer a plain miss -
    /// never throw, never crash.
    func testAPurgedDirectoryIsAMissNotACrash() async throws {
        let root = makeTempRoot()
        let url = URL(string: "https://gym.example/gif/0043-purge111.gif")!
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Self.pixelGIF.write(to: root.appendingPathComponent(url.lastPathComponent))

        // The system emptying Caches between launches - the whole directory
        // this cache was writing into is simply gone.
        try FileManager.default.removeItem(at: root)

        let cache = GymMediaCache(root: root, session: stubbedSession())
        let result = await cache.quickImage(for: url)
        XCTAssertNil(result, "a purged directory must read as a miss, not survive as a hit")

        // And the cache still WORKS afterwards - a purge is not a wound that
        // needs the directory recreated by hand.
        GymMediaStubProtocol.reset()
        let refetched = await cache.image(for: url)
        XCTAssertNotNil(refetched)
    }

    // MARK: - Purging on request

    /// What Settings' "delete downloaded files and cached pages" button
    /// relies on: everything this cache put on disk and in memory is gone
    /// afterwards, and asking for the same URL again is a genuine fetch.
    func testPurgeDropsBothTheDiskFileAndTheMemoryCopy() async {
        let root = makeTempRoot()
        let cache = GymMediaCache(root: root, session: stubbedSession())
        let url = URL(string: "https://gym.example/gif/0043-purge222.gif")!
        _ = await cache.image(for: url)
        let beforePurge = await cache.quickImage(for: url)
        XCTAssertNotNil(beforePurge)

        await cache.purge()

        let afterPurge = await cache.quickImage(for: url)
        XCTAssertNil(afterPurge)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(url.lastPathComponent).path))
    }
}

// MARK: - Prefetch set computation

/// What belongs in the working set: every routine's own exercises, plus
/// whatever was trained in the last month - and nothing else. Pure over a
/// state and a library, so these run with no cache, no disk and no network at
/// all.
final class GymMediaPrefetchTests: XCTestCase {

    private let library = GymLibrary(mediaBase: "https://gym.example/gif/", exercises: [
        GymLibraryEntry(id: "0043", name: "barbell full squat", bodyPart: "upper legs",
                        equipment: "barbell", gif: "0043-squat01.gif"),
        GymLibraryEntry(id: "0652", name: "pull-up", bodyPart: "back",
                        equipment: "body weight", gif: "0652-pullup1.gif"),
        GymLibraryEntry(id: "0003", name: "air bike", bodyPart: "waist",
                        equipment: "body weight", gif: "0003-airbik1.gif"),
        // In the catalogue, but the dataset has no animation for it - must
        // never contribute a URL.
        GymLibraryEntry(id: "9998", name: "mystery move", bodyPart: nil,
                        equipment: nil, gif: nil)
    ])

    private func routine(id: String, exerciseIDs: [String]) -> GymRoutine {
        GymRoutine(raw: [
            "id": .string(id), "name": .string(id),
            "ex": .array(exerciseIDs.map { .object(["id": .string($0), "sets": .int(3)]) })
        ])
    }

    private func workout(daysAgo: Int, exerciseIDs: [String]) -> JSONValue {
        let day = GymClock.day(Date().addingTimeInterval(-Double(daysAgo) * 86_400))
        let setRow: JSONValue = .object(["w": .number(10), "r": .int(5), "done": .bool(true)])
        let entries = exerciseIDs.map { id -> JSONValue in
            .object(["id": .string(id), "rid": .string("r1"), "sets": .array([setRow])])
        }
        return .object(["id": .string("w\(daysAgo)"), "d": .string(day),
                        "entries": .array(entries)])
    }

    /// A routine's own exercises are always in, whether or not they were ever
    /// trained - a routine just written has nothing in history yet.
    func testEveryRoutinesExercisesAreIncluded() {
        let state = GymState(raw: [
            "routines": .array([.object(routine(id: "r1",
                                                exerciseIDs: ["0043", "0652"]).raw)]),
            "workouts": .array([])
        ])
        let urls = GymMediaPrefetch.targetURLs(state: state, library: library)
        XCTAssertEqual(urls, [
            URL(string: "https://gym.example/gif/0043-squat01.gif")!,
            URL(string: "https://gym.example/gif/0652-pullup1.gif")!
        ])
    }

    /// An exercise trained recently but no longer in any routine - dropped
    /// from the split, still worth having on disk for the History page -
    /// counts too.
    func testAnExerciseOnlyInRecentHistoryIsIncluded() {
        let state = GymState(raw: [
            "routines": .array([]),
            "workouts": .array([workout(daysAgo: 5, exerciseIDs: ["0003"])])
        ])
        let urls = GymMediaPrefetch.targetURLs(state: state, library: library)
        XCTAssertEqual(urls, [URL(string: "https://gym.example/gif/0003-airbik1.gif")!])
    }

    /// Past the window, it drops out - the whole point of a WORKING set
    /// rather than every exercise ever done.
    func testHistoryOlderThanTheWindowIsExcluded() {
        let state = GymState(raw: [
            "routines": .array([]),
            "workouts": .array([workout(daysAgo: 45, exerciseIDs: ["0003"])])
        ])
        let urls = GymMediaPrefetch.targetURLs(state: state, library: library,
                                               historyDays: 30)
        XCTAssertTrue(urls.isEmpty)
    }

    /// A custom exercise, and a catalogue row with no animation, both drop
    /// out on their own - there is nothing to fetch for either.
    func testExercisesWithNoAnimationAreExcluded() {
        let state = GymState(raw: [
            "routines": .array([.object(routine(
                id: "r1", exerciseIDs: ["9998", "cdemoNoGif"]).raw)]),
            "workouts": .array([])
        ])
        let urls = GymMediaPrefetch.targetURLs(state: state, library: library)
        XCTAssertTrue(urls.isEmpty)
    }

    /// The same exercise in both a routine AND recent history contributes ONE
    /// URL, not two - the ordinary case for anything still being trained.
    func testTheSameExerciseInARoutineAndHistoryIsNotDuplicated() {
        let state = GymState(raw: [
            "routines": .array([.object(routine(id: "r1", exerciseIDs: ["0043"]).raw)]),
            "workouts": .array([workout(daysAgo: 2, exerciseIDs: ["0043"])])
        ])
        let urls = GymMediaPrefetch.targetURLs(state: state, library: library)
        XCTAssertEqual(urls.count, 1)
    }

    /// Against the shape of a real profile - `GymFixtures`' own routines and
    /// recent sessions - the set is exactly the catalogue ids the fixture
    /// actually uses, no more.
    func testAgainstTheDemoFixture() {
        let document = GymFixtures.document()
        let library = GymFixtures.library()
        let urls = GymMediaPrefetch.targetURLs(state: document.state, library: library)

        let expectedIDs = ["0043", "0652", "0003",
                           "cdemoa06", "cdemob02", "cdemoc01", "cdemoc04"]
        let expected = Set(expectedIDs.compactMap { id -> URL? in
            guard let entry = library.exercises.first(where: { $0.id == id }) else { return nil }
            return library.gifURL(for: entry)
        })
        XCTAssertEqual(urls, expected)
        // And nothing from the roughly twenty PURE customs with no overlay -
        // this is the working set, not the whole document.
        XCTAssertLessThan(urls.count, document.state.routines
            .reduce(0) { $0 + $1.exercises.count })
    }
}

// MARK: - The network stub

/// A `URLProtocol` that answers every request with the same pixel GIF,
/// counting requests so a test can assert coalescing, and delayable so two
/// concurrent callers actually overlap rather than serializing by accident.
private final class GymMediaStubProtocol: URLProtocol {

    private static let lock = NSLock()
    nonisolated(unsafe) private static var count = 0
    nonisolated(unsafe) static var responseDelay: TimeInterval = 0

    static var requestCount: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }

    static func reset() {
        lock.lock(); count = 0; responseDelay = 0; lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock(); Self.count += 1; let delay = Self.responseDelay; Self.lock.unlock()
        let deadline = DispatchTime.now() + delay
        DispatchQueue.global().asyncAfter(deadline: deadline) { [weak self] in
            guard let self, let url = self.request.url else { return }
            let response = HTTPURLResponse(url: url, statusCode: 200,
                                           httpVersion: "HTTP/1.1", headerFields: nil)!
            self.client?.urlProtocol(self, didReceive: response,
                                     cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: GymMediaCacheTests.pixelGIFForStub)
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

extension GymMediaCacheTests {
    /// Exposed for the stub protocol above, which lives outside the test
    /// case and cannot see its private fixture.
    fileprivate static var pixelGIFForStub: Data { pixelGIF }
}
