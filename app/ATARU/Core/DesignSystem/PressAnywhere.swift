import SwiftUI
import UIKit

/// A long press anywhere on screen, reported with the point it happened at.
///
/// ## Why this cannot be a SwiftUI gesture
///
/// `LongPressGesture` reports *that* a press happened, never *where* — and a
/// menu that opens under the thumb needs the point. `DragGesture` carries a
/// location but only fires on the view it is attached to, and attaching it to a
/// full-screen overlay would swallow every tap meant for the app underneath.
///
/// ## Why the recogniser lives on the window
///
/// Same reason as `TwoFingerSwipe`: a recogniser only receives touches when its
/// own view wins hit-testing, so the obvious "invisible overlay that returns
/// `nil` from `hitTest`" never fires — passing touches through and receiving
/// them are mutually exclusive on one view. The window sits in the delivery
/// path for every touch regardless of which view wins, so a recogniser there
/// sees everything without stealing anything.
///
/// `cancelsTouchesInView` is `true`, which sounds like it would break the app
/// and does not: a recogniser only cancels touches once it *recognises*, and
/// this one needs `minimumPressDuration` to elapse first. Taps and scrolls are
/// therefore untouched; what it does cancel is the button you happened to be
/// resting on when the menu opened, which is exactly right — otherwise letting
/// go would both pick a destination and press whatever was underneath.
struct PressAnywhere: UIViewRepresentable {
    /// Turned off during a call and while the keyboard is up. Disabling the
    /// recogniser is the only thing that works: `allowsHitTesting` cannot
    /// reach a recogniser that is not attached to this view in the first place.
    var isEnabled: Bool
    /// Rects, in global coordinates, where a press means something else. The
    /// orb is the one that matters — holding it is how you talk to ATARU, and
    /// a menu opening a third of a second into every question would make the
    /// app unusable.
    var exclusions: [CGRect]

    var onBegan: (CGPoint) -> Void
    var onMoved: (CGPoint) -> Void
    var onEnded: () -> Void

    func makeUIView(context: Context) -> UIView {
        AttachingView(coordinator: context.coordinator)
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.exclusions = exclusions
        context.coordinator.onBegan = onBegan
        context.coordinator.onMoved = onMoved
        context.coordinator.onEnded = onEnded
        context.coordinator.setEnabled(isEnabled)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(exclusions: exclusions, onBegan: onBegan, onMoved: onMoved, onEnded: onEnded)
    }

    /// Invisible; exists only to reach the window and hang the recogniser on it.
    final class AttachingView: UIView {
        private let coordinator: Coordinator

        init(coordinator: Coordinator) {
            self.coordinator = coordinator
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            backgroundColor = .clear
        }

        required init?(coder: NSCoder) { fatalError("unused") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            coordinator.attach(to: window)
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var exclusions: [CGRect]
        var onBegan: (CGPoint) -> Void
        var onMoved: (CGPoint) -> Void
        var onEnded: () -> Void

        private var recognizer: UILongPressGestureRecognizer?
        private var isEnabled = true
        /// True between a press we accepted and its release, so a cancel or a
        /// disable mid-press still closes the menu exactly once.
        private var isTracking = false

        init(exclusions: [CGRect],
             onBegan: @escaping (CGPoint) -> Void,
             onMoved: @escaping (CGPoint) -> Void,
             onEnded: @escaping () -> Void) {
            self.exclusions = exclusions
            self.onBegan = onBegan
            self.onMoved = onMoved
            self.onEnded = onEnded
        }

        func attach(to window: UIWindow?) {
            // Leaving a window always detaches first, so a recogniser never
            // outlives the view that owns its callbacks.
            if let recognizer { recognizer.view?.removeGestureRecognizer(recognizer) }
            recognizer = nil

            guard let window else { return }
            let press = UILongPressGestureRecognizer(
                target: self, action: #selector(handle(_:)))
            // Near UIKit's own 0.5 default rather than the snappier 0.32 this
            // started at. The launcher competes with every tap in the app, so
            // the cost of firing too eagerly is not a slightly early animation
            // — it is a button press cancelled and a screen the user did not
            // ask for. Slow taps happen; accidental navigation is worse than a
            // fan that takes another tenth of a second.
            press.minimumPressDuration = 0.45
            // A little more slack than the default 10: reaching a thumb across
            // a phone drifts, and a press that dies from a wobble reads as the
            // gesture simply not working.
            press.allowableMovement = 14
            press.delegate = self
            press.cancelsTouchesInView = true
            window.addGestureRecognizer(press)
            press.isEnabled = isEnabled
            recognizer = press
        }

        func setEnabled(_ enabled: Bool) {
            guard isEnabled != enabled else { return }
            isEnabled = enabled
            recognizer?.isEnabled = enabled
            // Toggling `isEnabled` cancels an in-flight gesture without ever
            // sending `.ended`, which would strand the menu open forever.
            //
            // Deferred, because this runs from `updateUIView` — inside a
            // SwiftUI update — and closing the menu writes state that the same
            // update is reading.
            if !enabled {
                DispatchQueue.main.async { [weak self] in self?.finish() }
            }
        }

        @objc private func handle(_ press: UILongPressGestureRecognizer) {
            let point = press.location(in: press.view)
            switch press.state {
            case .began:
                isTracking = true
                onBegan(point)
            case .changed:
                guard isTracking else { return }
                onMoved(point)
            case .ended, .cancelled, .failed:
                finish()
            default:
                break
            }
        }

        private func finish() {
            guard isTracking else { return }
            isTracking = false
            onEnded()
        }

        /// The one place a press is turned down: inside a rect that has its own
        /// meaning for being held.
        func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
            let point = gesture.location(in: gesture.view)
            return !exclusions.contains { $0.contains(point) }
        }

        /// Never claims a gesture exclusively while it is still pending — lists
        /// keep scrolling and buttons keep taking taps right up until the press
        /// is actually recognised.
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool { true }
    }
}

// MARK: - Exclusions

/// Collects the rects that opt out of the press menu, in global coordinates.
struct PressExclusionKey: PreferenceKey {
    static let defaultValue: [CGRect] = []

    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) {
        value.append(contentsOf: nextValue())
    }
}

extension View {
    /// Marks this view as somewhere a long press means something other than
    /// "open the launcher" — the orb, which is held to talk, and the composer,
    /// where a hold is how you reach the selection magnifier.
    func pressMenuExclusion() -> some View {
        background(
            GeometryReader { geo in
                Color.clear.preference(key: PressExclusionKey.self,
                                       value: [geo.frame(in: .global)])
            }
        )
    }
}
