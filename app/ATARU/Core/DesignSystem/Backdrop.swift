import SwiftUI

/// The app's background, anchored to the WINDOW rather than to whatever view
/// happens to be painting it.
///
/// ## The bug this ends, for good this time
///
/// "When I open a tile I haven't opened in a long time, the vertical rectangle
/// bar that's off colour pops up." Same words as 2026-08-14, same family as
/// a9bbf82, third appearance.
///
/// `Ataru.backdrop` is a RadialGradient whose centre is `UnitPoint(x: 0.5,
/// y: -0.2)` - twenty percent of the PAINTING VIEW'S HEIGHT above its own top -
/// with an absolute 900pt end radius. That makes the gradient a function of
/// the frame it is drawn into. Two views painting the identical gradient at
/// different sizes or origins get visibly different shading, and where they
/// overlap the difference has a hard edge along the frame boundary.
///
/// That is precisely the tile-screen arrangement: the host paints the backdrop
/// across the whole window, and each screen paints it again inside the
/// navigation stack, where the frame starts about 100pt lower and is 100pt
/// shorter. The inner copy's bright core lands roughly 120pt further down the
/// screen than the outer one's, so the content area reads as a lighter
/// rectangle sitting on a darker page - most obvious on a cold open, where
/// there is no content drawn over it yet to disguise it.
///
/// Removing the inner backdrops was the obvious fix and is the wrong one: a
/// screen pushed onto the navigation stack has to be opaque, or the view it
/// slid in over shows through it during the push.
///
/// So the gradient is anchored instead. Every copy is positioned as though it
/// were painted from the top of the window, which makes every copy pixel
/// identical, which makes overlapping copies invisible - whoever paints it,
/// whenever, at whatever size. The class of bug is gone rather than one
/// instance of it.
struct AtaruBackdrop: View {
    var body: some View {
        GeometryReader { geo in
            // How far down the window this view starts. `.global` is the
            // window's space, which is the anchor the gradient needs.
            let dropped = max(0, geo.frame(in: .global).minY)
            Ataru.backdrop
                // Extended upward to the top of the window and then slid back
                // into place: the gradient's box now starts where the window
                // does, so its centre is at the same absolute point on screen
                // for every view that paints it.
                .frame(width: geo.size.width, height: geo.size.height + dropped)
                .offset(y: -dropped)
        }
        .ignoresSafeArea()
        // Purely paint. Without this it would sit under the content taking
        // touches that belong to whatever is behind it.
        .allowsHitTesting(false)
    }
}
