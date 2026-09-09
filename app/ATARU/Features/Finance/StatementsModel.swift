import Foundation
import SwiftUI

/// The statement checklist's state, owned by the Finance pager.
///
/// ## Why a model rather than `@State` on the page
///
/// Two pages read it. The Statements page is the checklist itself, and the
/// Overview page carries the "N missing" chip - which has to be right the
/// moment Finance opens, without anybody swiping to page three. One fetch,
/// two consumers, and no chance of the chip disagreeing with the list it
/// jumps to.
@MainActor
final class StatementsModel: ObservableObject {

    @Published private(set) var payload: StatementsDTO?
    @Published private(set) var failed = false
    /// Set when what is on screen came off disk. Same contract as every other
    /// tile screen: last known content first, then the network.
    @Published private(set) var cachedAt: Date?

    @Published private(set) var isUploading = false
    /// Per-file accepted / rejected, from the last upload.
    @Published private(set) var lastUpload: StatementsUploadDTO?
    @Published private(set) var uploadFailure: String?
    /// True between an accepted upload and the second re-check. An accepted
    /// upload means the file landed in the inbox, NOT that it was ingested -
    /// so the page says the checklist is still catching up rather than
    /// claiming the row is filed.
    @Published private(set) var isIngesting = false

    private var root: URL?
    private var isDemo = false
    private var pollTask: Task<Void, Never>?

    /// The cache key, shared with `TileCache.kinds` so a purge finds it.
    static let cacheKind = "statements"

    func configure(root: URL?, isDemo: Bool) {
        self.root = root
        self.isDemo = isDemo
    }

    var missingCount: Int { payload?.missingCount ?? 0 }

    // MARK: - Loading

    func restore() async {
        guard payload == nil, !isDemo,
              let cached = await TileCache.load(StatementsDTO.self,
                                                kind: Self.cacheKind, for: root)
        else { return }
        payload = cached.payload
        cachedAt = cached.savedAt
    }

    func load() async {
        // DEMO IS SERVED FROM FIXTURES, unlike the Overview page beside it.
        //
        // That difference is deliberate. Overview degrades to an error in Demo
        // because there is nothing sensible to invent about somebody's net
        // worth. A statement CHECKLIST has no numbers in it - it is six
        // account names and whether a file arrived - so it can be shown
        // honestly with synthetic rows, and a page nobody can see is a page
        // nobody reviews.
        if isDemo {
            payload = DemoFixtures.statements()
            failed = false
            cachedAt = nil
            return
        }
        guard let root else { return }
        do {
            let fresh = try await TileFetch.get(
                StatementsDTO.self, root.appending(path: "api/statements"))
            withAnimation(Theme.quick) {
                payload = fresh
                failed = false
                cachedAt = nil
            }
            TileCache.save(fresh, kind: Self.cacheKind, for: root)
        } catch {
            guard !TileFetchError.isCancellation(error) else { return }
            failed = true
        }
    }

    // MARK: - Uploading

    /// Sends picked files to the inbox, then re-checks the list twice.
    ///
    /// Nothing here claims a statement was filed. The server accepts a file
    /// into the inbox and ingests it separately - seconds to a minute later -
    /// so the only truthful confirmation is the checklist changing by itself,
    /// which is what the two re-fetches are for.
    func upload(_ picked: [URL]) async {
        guard !picked.isEmpty else { return }
        guard !isDemo else {
            uploadFailure = "Demo mode has no server to upload to."
            return
        }
        guard let root else { return }

        lastUpload = nil
        uploadFailure = nil
        isUploading = true
        defer { isUploading = false }

        let parts: [MultipartBody.Part]
        do {
            // Off the main actor: this is a synchronous read of whole PDFs,
            // and the page it would block is the one showing the spinner.
            parts = try await Task.detached(priority: .userInitiated) {
                try Self.read(picked)
            }.value
        } catch {
            uploadFailure = "Couldn't read the files you picked."
            return
        }
        guard !parts.isEmpty else {
            uploadFailure = "Couldn't read the files you picked."
            return
        }

        do {
            let result = try await TileFetch.postMultipart(
                StatementsUploadDTO.self,
                root.appending(path: "api/statements/upload"),
                parts: parts)
            lastUpload = result
            guard !(result.accepted ?? []).isEmpty else { return }
            startIngestPolling()
        } catch {
            guard !TileFetchError.isCancellation(error) else { return }
            uploadFailure = (error as? TileFetchError)?.errorDescription
                ?? "The upload didn't land."
        }
    }

    /// Re-checks at 3s and 15s, which is the ingest window the finance service
    /// documents. A timer that kept going would be a poller, and this is a
    /// page somebody is looking at for ten seconds.
    private func startIngestPolling() {
        pollTask?.cancel()
        isIngesting = true
        pollTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            await self?.load()
            try? await Task.sleep(for: .seconds(12))
            guard !Task.isCancelled else { return }
            await self?.load()
            self?.isIngesting = false
        }
    }

    func cancelPolling() {
        pollTask?.cancel()
        pollTask = nil
        isIngesting = false
    }

    /// Reads picked files off disk, honouring the security scope.
    ///
    /// A URL from the Files app points OUTSIDE the app's container and is
    /// readable only between `startAccessingSecurityScopedResource` and its
    /// stop. Without the pair the read fails with a permission error that
    /// looks exactly like a missing file, and only for files picked from
    /// iCloud Drive or another app's container - which is most of them.
    ///
    /// `nonisolated` and off the main actor: this is a synchronous read of
    /// whole PDFs.
    private nonisolated static func read(_ urls: [URL]) throws -> [MultipartBody.Part] {
        var parts: [MultipartBody.Part] = []
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            let name = url.lastPathComponent
            parts.append(MultipartBody.Part(
                filename: name,
                contentType: MultipartBody.contentType(forFilename: name),
                data: data))
        }
        return parts
    }
}
