import Foundation

/// Owns every document this app has pulled onto the phone.
///
/// Downloaded vault files are the most sensitive thing the app touches, so
/// they are confined to one scratch directory rather than scattered through
/// `NSTemporaryDirectory()`. That makes "delete everything we cached" a single
/// call, which `purge()` is, and which the app performs when it backgrounds.
///
/// The directory is excluded from backup: these are copies of files that
/// already live on the user's own server, and there is no reason for them to
/// travel to iCloud from here.
///
/// ## Why a purge is reference counted
///
/// THE BUG THIS FIXES. `purge` ran on `scenePhase == .background`, and the
/// things that background this app are the exact things that are still reading
/// these files: AirDrop, Save to Files, and attaching to Mail all hand the URL
/// to another process and put ATARU behind it. So the app deleted the file it
/// had just offered, at the moment the receiver went to copy it, and the share
/// failed or landed empty.
///
/// So a file in use is retained for as long as it is presented, and only what
/// nothing is holding gets deleted. Anything still held is dropped on the next
/// release. Callers that hand a URL to another process - a share sheet, a
/// QuickLook preview, an audio player working from a file on disk - are
/// expected to `retain` around it and `release` afterwards.
actor DocumentDownloadStore {

    static let shared = DocumentDownloadStore()

    private let root: URL
    private let fileManager = FileManager.default
    /// The download boxes something is still reading.
    private var retained: [URL: Int] = [:]
    /// A purge that could not finish because something was in use, so the next
    /// release finishes it.
    private var purgeDeferred = false

    init(root: URL? = nil) {
        self.root = root ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ataru-documents", isDirectory: true)
    }

    /// Writes `data` under a filename safe for the share sheet.
    ///
    /// The filename matters more than it looks: it is what the recipient sees
    /// in Mail or AirDrop, so it uses the document's real title rather than an
    /// opaque id.
    func store(_ data: Data, preferredName: String) throws -> URL {
        // A fresh download means the app is in front and fetching again, so a
        // purge left over from the last backgrounding is spent: finishing it
        // later would delete a file pulled after it was asked for. The next
        // backgrounding purges whatever is left over.
        purgeDeferred = false
        try prepareRoot()
        // A fresh subdirectory per download, so two files with the same title
        // cannot overwrite each other mid-share.
        let box = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: box, withIntermediateDirectories: true)

        let destination = box.appendingPathComponent(Self.sanitize(preferredName))
        try data.write(to: destination, options: .atomic)
        return destination
    }

    /// Marks a downloaded file as in use, so a purge leaves it alone.
    ///
    /// Counted rather than a flag: the same file is routinely previewed and
    /// then shared, and the two presentations overlap.
    func retain(_ url: URL) {
        let box = Self.box(of: url, under: root)
        retained[box, default: 0] += 1
    }

    /// Gives a file back. A purge that was waiting on it happens now.
    func release(_ url: URL) {
        let box = Self.box(of: url, under: root)
        guard let count = retained[box] else { return }
        if count <= 1 { retained[box] = nil } else { retained[box] = count - 1 }
        if purgeDeferred { purge() }
    }

    /// Removes every downloaded document that nothing is still reading.
    ///
    /// Whatever is in use survives this call and goes on the next release, so
    /// backgrounding mid-share no longer deletes the file being shared.
    func purge() {
        guard !retained.isEmpty else {
            purgeDeferred = false
            try? fileManager.removeItem(at: root)
            return
        }
        purgeDeferred = true
        let boxes = (try? fileManager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil)) ?? []
        for box in boxes where retained[box.standardizedFileURL] == nil {
            try? fileManager.removeItem(at: box)
        }
    }

    /// The per-download directory a file sits in - what retention is keyed on,
    /// since that is the unit `store` creates and `purge` removes.
    private static func box(of url: URL, under root: URL) -> URL {
        let file = url.standardizedFileURL
        let parent = file.deletingLastPathComponent().standardizedFileURL
        // A URL from somewhere else is keyed as itself rather than silently
        // retaining a directory this store does not own.
        guard parent.deletingLastPathComponent().standardizedFileURL
            == root.standardizedFileURL else { return file }
        return parent
    }

    private func prepareRoot() throws {
        guard !fileManager.fileExists(atPath: root.path) else { return }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        var mutable = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? mutable.setResourceValues(values)
    }

    /// Strips path separators and leading dots from a server-supplied title.
    ///
    /// The title comes from the server, so it is treated as untrusted: a name
    /// containing `/` or `..` must not be able to steer the write out of the
    /// scratch directory.
    static func sanitize(_ name: String) -> String {
        let cleaned = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        return cleaned.isEmpty ? "document" : String(cleaned.prefix(120))
    }
}
