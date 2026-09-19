import SwiftUI
import UIKit

/// Thumbnails, fetched once per file and kept for the session.
///
/// An ABSENCE is cached as deliberately as an image. The server answers 204
/// for anything it cannot render, and without remembering that, a list of
/// videos would re-ask for the same missing thumbnail every time a row
/// scrolled back into view.
actor FilePreviewCache {
    static let shared = FilePreviewCache()

    /// `nil` value means "asked, and there is none".
    private var entries: [String: Data?] = [:]
    private var inFlight: [String: Task<Data?, Never>] = [:]

    func data(for id: String, service: ATARUService) async -> Data? {
        if let entry = entries[id] { return entry }
        if let running = inFlight[id] { return await running.value }
        let task = Task<Data?, Never> { await service.filePreview(id: id) }
        inFlight[id] = task
        let result = await task.value
        inFlight[id] = nil
        entries[id] = result
        return result
    }

    /// Dropped along with everything else ATARU has put on this phone.
    func purge() {
        entries.removeAll()
        inFlight.values.forEach { $0.cancel() }
        inFlight.removeAll()
    }
}

/// A row's leading square: the thumbnail once it arrives, the kind icon until
/// then, and the kind icon forever when there is none.
///
/// The icon is not a placeholder that gets replaced by a spinner - a list of
/// thirty spinners is worse than a list of thirty icons, and the icon is
/// already the correct answer for most rows.
struct FileThumbnail: View {
    let hit: FileHit
    let service: ATARUService
    var side: CGFloat = 46

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                .fill(Theme.surfaceElevated)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small,
                                                style: .continuous))
                    .transition(.opacity)
            } else {
                Image(systemName: hit.kind.symbol)
                    .font(.system(size: side * 0.42, weight: .light))
                    .foregroundStyle(Theme.cyanSubdued)
            }
        }
        .frame(width: side, height: side)
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                .strokeBorder(Theme.border, lineWidth: 1)
        }
        .accessibilityHidden(true)
        // Lazily, and only for files that could have one. A tiered-out file's
        // bytes are on the NAS, so there is nothing on this host to render.
        .task(id: hit.id) {
            guard image == nil, !hit.location.isAway else { return }
            let data = await FilePreviewCache.shared.data(for: hit.id, service: service)
            guard let data, let decoded = UIImage(data: data) else { return }
            withAnimation(Theme.quick) { image = decoded }
        }
    }
}
