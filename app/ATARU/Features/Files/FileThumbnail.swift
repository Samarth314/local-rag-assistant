import ImageIO
import SwiftUI
import UIKit

/// Turns a preview's bytes into a bitmap the size of the square it goes in,
/// and never larger.
///
/// ## Why not `UIImage(data:)`
///
/// It looks free and is not. It keeps the file's own pixels - a phone
/// screenshot is around 1200x2600, a photo more - and defers the actual
/// decode to the first time the image is DRAWN, which is on the main thread,
/// mid-scroll. Measured on the fixture, one 1260x840 preview cost between
/// 0.7 and 11.9ms of main thread and about 4.2MB of bitmap to fill a 46pt
/// square that needs 19k pixels. Thirty rows of that is the stutter.
///
/// `CGImageSourceCreateThumbnailAtIndex` decodes straight to the size asked
/// for, off the main thread, and `kCGImageSourceShouldCacheImmediately` makes
/// it happen HERE rather than at draw time - which is the whole point, since
/// moving the decode off the main thread is worthless if the main thread is
/// still where it lands.
enum FileThumbnailDecoder {

    /// How far out of square a picture may be before it stops being sampled
    /// at full sharpness.
    ///
    /// Up to 8:1 the short side gets exactly the pixels the square needs. Past
    /// that the long side is capped and the crop goes slightly soft, which is
    /// the right trade: a 20:1 panorama shows a twentieth of itself in a
    /// square, and the alternative is letting one row ask for twenty times the
    /// memory of an ordinary photo.
    static let aspectCeiling: CGFloat = 8

    /// The pixel budget for a square of `side` points at `scale`.
    ///
    /// A `.fill` crop scales the image until its SHORT side covers the
    /// square, so the short side is what has to be big enough. Asking for
    /// the long side instead is how a wide picture ends up sampled to a few
    /// pixels tall and drawn as a smear.
    static func maxPixelSize(side: CGFloat, scale: CGFloat, aspect: CGFloat) -> Int {
        let target = max(1, side * scale)
        let ratio = min(max(aspect, 1 / max(aspect, 0.0001)), aspectCeiling)
        return Int((target * ratio).rounded())
    }

    /// `nil` when the bytes are not an image this device can read - which is
    /// the same answer as "the server had no thumbnail", and the row draws
    /// its kind icon either way.
    static func thumbnail(from data: Data, side: CGFloat, scale: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = (properties?[kCGImagePropertyPixelWidth] as? CGFloat) ?? 1
        let height = (properties?[kCGImagePropertyPixelHeight] as? CGFloat) ?? 1
        let aspect = height > 0 ? width / height : 1
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize:
                maxPixelSize(side: side, scale: scale, aspect: aspect)
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(
            source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
}

/// Thumbnails, fetched once per file and kept for the session.
///
/// DECODED rather than raw now. The cache used to hold the bytes and leave
/// every row to turn them into a picture, which meant the expensive half
/// happened once per row appearance rather than once per file, and happened
/// on the main thread.
///
/// An ABSENCE is cached as deliberately as an image. The server answers 204
/// for anything it cannot render, and without remembering that, a list of
/// videos would re-ask for the same missing thumbnail every time a row
/// scrolled back into view.
actor FileThumbnailCache {
    static let shared = FileThumbnailCache()

    /// `nil` value means "asked, and there is none".
    private var entries: [String: UIImage?] = [:]
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    func thumbnail(for id: String, side: CGFloat, scale: CGFloat,
                   service: ATARUService) async -> UIImage? {
        if let entry = entries[id] { return entry }
        if let running = inFlight[id] { return await running.value }
        let task = Task.detached(priority: .utility) { () -> UIImage? in
            guard let data = await service.filePreview(id: id), !data.isEmpty,
                  !Task.isCancelled
            else { return nil }
            return FileThumbnailDecoder.thumbnail(from: data, side: side, scale: scale)
        }
        inFlight[id] = task
        let result = await task.value
        inFlight[id] = nil
        // A CANCELLED FETCH IS NOT AN ANSWER. Recording its nil would mean a
        // row that scrolled past mid-request never gets a thumbnail again
        // for the life of the session, which is worse than the request it
        // was trying to save.
        guard !task.isCancelled else { return nil }
        entries[id] = result
        return result
    }

    /// Drops a request nobody is waiting for any more. Called when a row
    /// scrolls off: a sweep through four hundred files should not leave four
    /// hundred requests in flight for pictures that are long gone.
    func cancel(_ id: String) {
        guard entries[id] == nil, let running = inFlight[id] else { return }
        running.cancel()
        inFlight[id] = nil
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
///
/// ## IT IS A SQUARE, WHATEVER ARRIVES
///
/// "Several PNG rows render their preview as a full-width white strip that
/// spills out of the row and over neighbouring rows, covering the file name."
/// A `.fill` aspect ratio gives the image the LAYOUT SIZE it needs to cover
/// the square - for a 3200x360 screenshot in a 46pt box that is 409pt wide -
/// and a ZStack does not clip, so the picture was drawn at its full width
/// across everything beside it. Clipping the Image to its own rounded
/// rectangle did nothing, because its own frame was the 409pt one.
///
/// So the square is imposed BEFORE the clip: frame, then `clipped()`, then
/// the corner radius. Every state is inside the same fixed frame, so nothing
/// the server sends can move a single point of this row.
struct FileThumbnail: View {
    let hit: FileHit
    let service: ATARUService
    var side: CGFloat = 46

    @State private var image: UIImage?
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                .fill(Theme.surfaceElevated)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    // The square, imposed on the picture itself. Everything
                    // else in this view was already square; this is the one
                    // that was not.
                    .frame(width: side, height: side)
                    .clipped()
                    .transition(.opacity)
            } else {
                Image(systemName: hit.kind.symbol)
                    .font(.system(size: side * 0.42, weight: .light))
                    .foregroundStyle(Theme.cyanSubdued)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                .strokeBorder(Theme.border, lineWidth: 1)
        }
        // Belt and braces, and cheap: whatever a future state draws in here,
        // the row's layout cannot be moved by it.
        .fixedSize()
        .accessibilityHidden(true)
        // Lazily, and only for files that could have one. A tiered-out file's
        // bytes are on the NAS, so there is nothing on this host to render.
        .task(id: hit.id) {
            guard image == nil, !hit.location.isAway else { return }
            let id = hit.id
            let loaded = await withTaskCancellationHandler {
                await FileThumbnailCache.shared.thumbnail(
                    for: id, side: side, scale: displayScale, service: service)
            } onCancel: {
                Task { await FileThumbnailCache.shared.cancel(id) }
            }
            guard !Task.isCancelled, let loaded else { return }
            withAnimation(Theme.quick) { image = loaded }
        }
    }
}
