import ImageIO
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - Playing a GIF

/// An animated GIF, decoded with ImageIO and played by UIKit.
///
/// SwiftUI's `Image` draws the FIRST FRAME of a GIF and stops, which for an
/// exercise demonstration is a still of someone standing next to a rack. There
/// is no SwiftUI animated-image view and no dependency was added for this:
/// ImageIO is in the SDK, `UIImage.animatedImage(with:duration:)` plays a
/// frame array, and a twenty-line `UIViewRepresentable` is the whole bridge.
///
/// ## Frame timing
///
/// A GIF's frames each carry their own delay and `UIImage.animatedImage` only
/// takes one duration for all of them, so the frames are REPEATED in
/// proportion to their delays against a common step. Ignoring that plays a
/// held pause at the top of a lift at the same speed as the lift.
///
/// The unclamped delay is read first: browsers clamp anything under 0.02s up
/// to 0.1s, and the dataset's animations are full of short frames that would
/// otherwise play five times slower than they do in openGym's own web app.
enum GymGIF {

    /// The step every frame count is expressed in. 20ms is the finest the
    /// format meaningfully carries.
    private static let step = 0.02

    static func animatedImage(from data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return nil }
        // A single-frame image is not an animation, and wrapping it in one
        // costs a display link forever for a still.
        guard count > 1 else {
            guard let frame = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                return nil
            }
            return UIImage(cgImage: frame)
        }

        var frames: [UIImage] = []
        var total: Double = 0
        for index in 0..<count {
            guard let frame = CGImageSourceCreateImageAtIndex(source, index, nil) else {
                continue
            }
            let delay = self.delay(of: source, at: index)
            let repeats = max(1, Int((delay / step).rounded()))
            let image = UIImage(cgImage: frame)
            for _ in 0..<repeats { frames.append(image) }
            total += Double(repeats) * step
        }
        guard !frames.isEmpty else { return nil }
        return UIImage.animatedImage(with: frames, duration: total)
    }

    private static func delay(of source: CGImageSource, at index: Int) -> Double {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil)
                as? [CFString: Any],
              let gif = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        else { return 0.1 }
        if let unclamped = gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double,
           unclamped > 0 {
            return unclamped
        }
        if let clamped = gif[kCGImagePropertyGIFDelayTime] as? Double, clamped > 0 {
            return clamped
        }
        return 0.1
    }
}

/// The UIKit half. Nothing but an image view that holds an animated `UIImage`.
private struct AnimatedImage: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> UIImageView {
        let view = UIImageView()
        view.contentMode = .scaleAspectFit
        view.clipsToBounds = true
        // Otherwise the view demands the GIF's intrinsic size and blows out
        // whatever row it is sitting in.
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        view.image = image
        return view
    }

    func updateUIView(_ view: UIImageView, context: Context) {
        if view.image !== image { view.image = image }
    }
}

// MARK: - Fetching one
//
// See `GymMediaCache` (this directory) for the actor that actually fetches
// and caches an animation - disk first, then the network, on-disk copy
// written before the image is handed back. `GymGIFView` below is its only
// caller.

// MARK: - The views

/// One exercise's animation, at whatever size it is given.
///
/// Three states and all three are drawn: loading, loaded, and no animation at
/// all. The third is not a failure - a custom exercise has no media by
/// definition - so it gets a neutral mark rather than a broken-image glyph.
struct GymGIFView: View {
    let url: URL?
    var cornerRadius: CGFloat = Theme.Radius.small
    /// Still frame only. A thumbnail in a list of fourteen rows animating at
    /// once is fourteen display links, and the detail page is where the
    /// movement is actually the point.
    var animated: Bool = true

    @State private var image: UIImage?
    @State private var isLoading = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Theme.surfaceElevated)

            if let image {
                if animated, image.images != nil {
                    AnimatedImage(image: image)
                } else {
                    Image(uiImage: image.images?.first ?? image)
                        .resizable()
                        .scaledToFit()
                }
            } else if url == nil {
                placeholder
            } else if isLoading {
                ProgressView()
                    .tint(Theme.textTertiary)
                    .scaleEffect(0.6)
            } else {
                placeholder
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .task(id: url) { await load() }
        .accessibilityHidden(true)
    }

    /// Neutral, and the same mark whether there is no animation or the fetch
    /// came back empty - "this exercise has no demo" is not an error worth a
    /// warning colour.
    private var placeholder: some View {
        Image(systemName: "figure.strengthtraining.traditional")
            .font(.system(size: 16, weight: .ultraLight))
            .foregroundStyle(Theme.textTertiary)
    }

    /// Disk (or an already-decoded copy in memory) shows immediately, with no
    /// spinner - `quickImage` never touches the network, so there is nothing
    /// to wait on. Only a genuine fetch shows the spinner, and only while it
    /// runs; a fetch that fails leaves `image` nil, which draws the same
    /// neutral placeholder as an exercise with no animation at all - never an
    /// error.
    private func load() async {
        image = nil
        guard let url else { return }
        if let hit = await GymMediaCache.shared.quickImage(for: url) {
            image = hit
            return
        }
        isLoading = true
        let fetched = await GymMediaCache.shared.image(for: url)
        isLoading = false
        image = fetched
    }
}

/// The small square on a row. Tappable when there is something to show.
struct GymExerciseThumbnail: View {
    let url: URL?
    var side: CGFloat = 40

    var body: some View {
        GymGIFView(url: url, animated: false)
            .frame(width: side, height: side)
    }
}

// MARK: - One exercise, full size

/// The page behind a thumbnail: the animation at full width, the name, and
/// what the dataset says it works.
///
/// Read-only on purpose. It is reached from a row that is already editable
/// somewhere else, and an editor here would be a second place to change the
/// same number.
struct GymExerciseDetail: View {
    let name: String
    let entry: GymLibraryEntry?
    let gifURL: URL?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                ATCard {
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        GymGIFView(url: gifURL, cornerRadius: Theme.Radius.tile)
                            .frame(maxWidth: .infinity)
                            .frame(height: 260)

                        Text(name)
                            .font(.ataruTitle())
                            .foregroundStyle(Theme.textPrimary)

                        if let entry, !entry.tagline.isEmpty {
                            HStack(spacing: Theme.Space.xs) {
                                if let part = entry.bodyPart, !part.isEmpty {
                                    ATPill(text: part, tone: Theme.cyan)
                                }
                                if let equipment = entry.equipment, !equipment.isEmpty {
                                    ATPill(text: equipment, tone: Theme.textSecondary)
                                }
                                Spacer(minLength: 0)
                            }
                        }

                        if gifURL == nil {
                            Text("No animation for this one - custom exercises "
                                 + "carry no media.")
                                .font(.ataruCaption())
                                .foregroundStyle(Theme.textTertiary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.Space.m)
                }
            }
            .padding(Theme.Space.screen)
        }
        .ataruBackdrop()
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
