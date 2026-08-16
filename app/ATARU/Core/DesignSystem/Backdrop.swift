import OSLog
import SwiftUI

/// The one place the app's background is painted.
///
///     log stream --device --predicate 'subsystem == "com.ataru.client" AND category == "backdrop"' --level debug
///
let backdropLog = Logger(subsystem: "com.ataru.client", category: "backdrop")

/// The app's background, anchored to the WINDOW rather than to whatever view
/// happens to be painting it.
///
/// ## The bug this ends
///
/// "When I open a tile I haven't opened in a long time, the vertical rectangle
/// bar that's off colour pops up." Reported three times, in three shapes.
///
/// `Ataru.backdrop` is a RadialGradient whose centre is `UnitPoint(x: 0.5,
/// y: -0.2)` - twenty percent of the PAINTING VIEW'S HEIGHT above its own top -
/// with an absolute 900pt end radius. That makes the gradient a function of the
/// frame it is drawn into. Two views painting the identical gradient at
/// different sizes or origins get visibly different shading, and where they
/// overlap the difference has a hard edge along the frame boundary.
///
/// That is precisely the tile-screen arrangement: the host paints the backdrop
/// across the whole window, and each screen paints it again inside the
/// navigation stack, where the frame starts about 100pt lower. The inner
/// copy's bright core lands roughly 120pt further down the screen, so the
/// content area reads as a lighter rectangle sitting on a darker page.
///
/// Removing the inner backdrops was the obvious fix and is the wrong one: a
/// screen pushed onto the navigation stack has to be opaque, or the view it
/// slid in over shows through it during the push.
///
/// So the gradient is anchored instead. Every copy is positioned as though it
/// were painted from the top of the window, which makes every copy pixel
/// identical, which makes overlapping copies invisible - whoever paints it,
/// whenever, at whatever size.
///
/// ## Why the flat base underneath
///
/// The anchoring needs a `GeometryReader`, and a GeometryReader has nothing to
/// report until the first layout pass has run. For that one frame the gradient
/// has no geometry to paint into, and whatever is behind shows through - on a
/// tile screen arriving over its own transition, that can be the window. So an
/// opaque base is painted first, from the app's own palette, and the gradient
/// lands on top of it. The two are within a couple of values of each other at
/// mid-screen, so the frame where only the base has painted is not a frame
/// anyone can see. It is deliberately NOT a spatial neighbour of the gradient -
/// it is completely covered from the first laid-out frame onward, which is the
/// difference between this and the flat `Palette.bg` that caused the original
/// report in 2026-08-14.
///
/// ## The instrument
///
/// Every zero-geometry layout - the only frame where the base is what is on
/// screen - is logged at debug level. If an off-colour pane is ever seen again,
/// the log says whether a surface was painting without geometry at that moment
/// and how big it thought it was, which is one command instead of another
/// guess. Debug level is never written to the persisted log, so it costs
/// nothing when nobody is streaming.
struct AtaruBackdrop: View {
    /// For the log, so a sighting names a surface rather than a view type.
    var surface: String = "unknown"

    var body: some View {
        ZStack {
            // Opaque, frame-independent, and painted before anything has been
            // measured. Nothing behind a tile surface can show through, ever.
            Ataru.Palette.bg
                .ignoresSafeArea()

            GeometryReader { geo in
                // How far down the window this view starts. `.global` is the
                // window's space, which is the anchor the gradient needs.
                let frame = geo.frame(in: .global)
                let dropped = max(0, frame.minY)
                Ataru.backdrop
                    // Extended upward to the top of the window and then slid
                    // back into place: the gradient's box now starts where the
                    // window does, so its centre is at the same absolute point
                    // on screen for every view that paints it.
                    .frame(width: geo.size.width,
                           height: geo.size.height + dropped)
                    .offset(y: -dropped)
                    .onAppear {
                        guard geo.size.width < 1 || geo.size.height < 1 else { return }
                        backdropLog.debug("""
                            \(surface, privacy: .public) painted with no geometry \
                            (\(geo.size.width, privacy: .public)x\
                            \(geo.size.height, privacy: .public)) - the flat base \
                            is what was on screen for that frame
                            """)
                    }
            }
            .ignoresSafeArea()
        }
        // Purely paint. Without this it would sit under the content taking
        // touches that belong to whatever is behind it.
        .allowsHitTesting(false)
    }
}
