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
actor DocumentDownloadStore {

    static let shared = DocumentDownloadStore()

    private let root: URL
    private let fileManager = FileManager.default

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
        try prepareRoot()
        // A fresh subdirectory per download, so two files with the same title
        // cannot overwrite each other mid-share.
        let box = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: box, withIntermediateDirectories: true)

        let destination = box.appendingPathComponent(Self.sanitize(preferredName))
        try data.write(to: destination, options: .atomic)
        return destination
    }

    /// Removes every downloaded document.
    func purge() {
        try? fileManager.removeItem(at: root)
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
