import Foundation
import UIKit

// MARK: - The cache

/// Exercise animations, kept on disk so the gym still shows them with one bar
/// of signal or none, and decoded copies held in memory for whatever has
/// already been drawn this session.
///
/// ## Why this exists instead of the memory-only cache it replaces
///
/// The GIFs are public static files on openGym's own web container and are
/// not Arya's data - WHICH ones this phone has asked for is closer to it,
/// because a folder of cached animations is a readable list of the exercises
/// he trains (vault CLAUDE.md, health-class). That is still true, and this
/// cache is held to the same bar as every other piece of health-class data on
/// this phone: excluded from backup, unreadable while the phone is locked
/// (`writeDiskData`), and part of "delete what ATARU has put on this phone"
/// (`purge()`, wired into `AppState.purgeDownloads`).
///
/// What changed is the other side of the tradeoff. A phone at the rack with
/// one bar of signal showed a spinner and then a placeholder for a routine of
/// exercises Arya opens every week, and a cache that starts empty on every
/// launch never gets ahead of that. The whole library is 1,324 files and
/// 126MB; what one training split actually touches is about twenty of them,
/// call it 2MB - a working set worth keeping on disk, not the library itself.
/// `GymMediaPrefetch` is what keeps this cache to that working set rather
/// than growing toward the whole catalogue.
///
/// ## Shape
///
/// Disk first, then the network, and a fetch writes what it found before
/// handing it back - `image(for:)` is the whole contract. In-flight requests
/// are coalesced by server filename, the same shape `FileThumbnailCache`
/// (Features/Files) uses for the same reason: eight rows asking for one
/// animation at once must cost one request, not eight.
actor GymMediaCache {

    static let shared = GymMediaCache()

    /// Decoded, animated `UIImage`s for whatever has been drawn this session.
    /// The disk file is the durable copy; this only saves re-decoding one
    /// already reached. A few dozen entries - roughly what one workout and
    /// its picker touch, not the working set on disk.
    private let memory: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 48
        return cache
    }()

    /// One request per server filename, however many views are waiting on it.
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    private let session: URLSession
    private let fileManager = FileManager.default
    private let root: URL

    init(root: URL? = nil, session: URLSession? = nil) {
        if let root {
            self.root = root
        } else {
            let dir = FileManager.default.urls(for: .cachesDirectory,
                                               in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            self.root = dir.appendingPathComponent("gym-media", isDirectory: true)
        }
        self.session = session ?? Self.makeSession()
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 20
        return URLSession(configuration: configuration)
    }

    // MARK: Reading

    /// Memory or disk only - never the network. What a view asks first, so an
    /// animation already local draws on the same frame instead of behind a
    /// spinner it does not need. `nil` is a real answer: not cached yet, ask
    /// `image(for:)` instead.
    func quickImage(for url: URL) -> UIImage? {
        let key = Self.key(for: url)
        if let hit = memory.object(forKey: key as NSString) { return hit }
        guard let data = readDiskData(for: key),
              let decoded = GymGIF.animatedImage(from: data) else { return nil }
        memory.setObject(decoded, forKey: key as NSString, cost: cost(of: decoded))
        return decoded
    }

    /// Disk, then the network - and a fetch is written to disk before it is
    /// handed back, so the next call (from any view, on any launch) is a disk
    /// hit. Concurrent callers for the same filename share one request.
    func image(for url: URL) async -> UIImage? {
        let key = Self.key(for: url)
        if let hit = memory.object(forKey: key as NSString) { return hit }
        if let data = readDiskData(for: key),
           let decoded = GymGIF.animatedImage(from: data) {
            memory.setObject(decoded, forKey: key as NSString, cost: cost(of: decoded))
            return decoded
        }
        if let running = inFlight[key] { return await running.value }

        let task = Task<UIImage?, Never> {
            guard let (data, response) = try? await self.session.data(from: url),
                  let http = response as? HTTPURLResponse, http.statusCode == 200,
                  !data.isEmpty,
                  let image = GymGIF.animatedImage(from: data)
            else { return nil }
            // Written before the image is handed back, so a second caller
            // that missed the in-flight coalescing above still finds it on
            // disk rather than fetching a second time.
            self.writeDiskData(data, key: key)
            return image
        }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        if let image { memory.setObject(image, forKey: key as NSString, cost: cost(of: image)) }
        return image
    }

    // MARK: Prefetching

    /// Downloads whatever in `urls` is not already on disk, a few at a time
    /// and at low priority. Nothing here is awaited by a view - this is
    /// warming the cache ahead of a tap, not a fetch anything on screen is
    /// waiting on, so a slow or absent connection costs nothing but time.
    func prefetch(_ urls: Set<URL>, concurrency: Int = 3) async {
        var missing: [URL] = []
        for url in urls where !diskHasFile(for: Self.key(for: url)) {
            missing.append(url)
        }
        guard !missing.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            var iterator = missing.makeIterator()
            func addNext() {
                guard let url = iterator.next() else { return }
                group.addTask(priority: .low) { _ = await self.image(for: url) }
            }
            for _ in 0..<min(concurrency, missing.count) { addNext() }
            while await group.next() != nil { addNext() }
        }
    }

    // MARK: Purging

    /// Drops every GIF this cache has put on disk, and every decoded copy
    /// held in memory. Part of "delete what ATARU has put on this phone",
    /// alongside the tile caches and the session file - see
    /// `AppState.purgeDownloads`.
    func purge() {
        memory.removeAllObjects()
        for task in inFlight.values { task.cancel() }
        inFlight.removeAll()
        try? fileManager.removeItem(at: root)
    }

    // MARK: Disk

    /// The name the server itself gave the file (`0043-qXTaZnJ.gif`), which is
    /// what this cache keys on rather than the full URL - so a filename
    /// reachable under two different hosts (the media base is server
    /// configurable, see `GymLibrary`) still hits the same file on disk.
    private static func key(for url: URL) -> String {
        let name = url.lastPathComponent
        return name.isEmpty
            ? url.absoluteString.replacingOccurrences(of: "/", with: "_")
            : name
    }

    private func fileURL(for key: String) -> URL {
        root.appendingPathComponent(key)
    }

    private func diskHasFile(for key: String) -> Bool {
        fileManager.fileExists(atPath: fileURL(for: key).path)
    }

    /// A MISSING file reads as a miss, never an error. Caches may be emptied
    /// by the system at any moment - a purged directory is the same cold
    /// state a brand new phone starts in, and this is the one place that
    /// difference has to be invisible.
    private func readDiskData(for key: String) -> Data? {
        try? Data(contentsOf: fileURL(for: key))
    }

    /// Unreadable while the phone is locked, like every other piece of
    /// health-class data this app writes - see `ActiveWorkoutStore` and
    /// `TileCache`. A failed write leaves the file simply absent, which this
    /// cache already treats as a miss rather than a reason to fail the fetch
    /// that is about to hand the image to a view regardless.
    private func writeDiskData(_ data: Data, key: String) {
        if !fileManager.fileExists(atPath: root.path) {
            guard (try? fileManager.createDirectory(
                at: root, withIntermediateDirectories: true)) != nil else { return }
            var mutableRoot = root
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? mutableRoot.setResourceValues(values)
        }
        try? data.write(to: fileURL(for: key), options: [.atomic, .completeFileProtection])
    }

    /// Frame count times one frame's bytes: the repeated frames share one
    /// `CGImage`, so this over-counts on purpose rather than under-counting
    /// and letting the cache grow past its limit. Copied from the cache this
    /// replaced.
    private func cost(of image: UIImage) -> Int {
        (image.images?.first?.cgImage).map { $0.bytesPerRow * $0.height } ?? 1
    }
}

// MARK: - What to prefetch

/// The working set: every exercise in every routine, plus every exercise
/// trained in the last month. Deliberately never the rest of openGym's
/// roughly 1,300 remaining exercises - see `GymMediaCache`'s own note on why
/// the whole library is not bundled or fetched.
enum GymMediaPrefetch {

    static let defaultHistoryDays = 30

    /// The GIF URLs worth having on disk before they are asked for.
    ///
    /// Deduplicated by URL rather than by exercise id: two ids can point at
    /// the same filename - the bridge's overlay lends a handful of custom
    /// exercise ids the dataset's own animation under another name (see
    /// `GymLibrary`) - and fetching the same file twice is exactly the
    /// duplicate work coalescing already avoids everywhere else in this
    /// cache. An exercise the catalogue has no animation for, or one not in
    /// the catalogue at all (a genuine custom), drops out on its own: looking
    /// it up in the index answers nil, or its `gifURL` does.
    static func targetURLs(state: GymState?, library: GymLibrary?,
                           now: Date = Date(),
                           historyDays: Int = defaultHistoryDays) -> Set<URL> {
        guard let state, let library else { return [] }
        let index = library.index()
        var ids = Set<String>()

        for routine in state.routines {
            for config in routine.exercises { ids.insert(config.id) }
        }

        if let cutoff = Calendar(identifier: .gregorian)
            .date(byAdding: .day, value: -historyDays, to: now) {
            let cutoffDay = GymClock.day(cutoff)
            // `day` is `YYYY-MM-DD`, so the lexical comparison is the date
            // comparison - no parsing needed for a bound this loose.
            for workout in state.workouts where workout.day >= cutoffDay {
                for entry in workout.entries { ids.insert(entry.id) }
            }
        }

        return Set(ids.compactMap { id in index[id].flatMap(library.gifURL(for:)) })
    }
}
