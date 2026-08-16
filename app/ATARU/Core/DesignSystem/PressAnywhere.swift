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
    /// a menu opening a fifth of a second into every question would make the
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
            // 0.22s, down from 0.45 (and 0.32 before that). 0.45 was chosen
            // to sit near UIKit's own 0.5 default on the grounds that the
            // launcher competes with every tap in the app, so firing eagerly
            // costs a cancelled button press and a screen nobody asked for.
            // That reasoning was right about the risk and wrong about which
            // gate carries it: waiting is not what tells a hold apart from a
            // tap or a scroll, movement is. A tap is gone in ~0.1s and never
            // reaches even this threshold, and a scroll is moving from the
            // first frame.
            //
            // So the time gate comes down to where the fan feels like it
            // answers the thumb, and the movement gate below takes over the
            // job of turning down everything that is not a deliberate hold.
            press.minimumPressDuration = 0.22
            // Back to UIKit's default 10, from the 14 that ran alongside the
            // longer wait. The slack was there because a thumb reaching across
            // a phone drifts and a press dying from a wobble reads as the
            // gesture simply not working - but drift is a function of how long
            // the finger has to sit still, and that is now half what it was.
            // At 0.22s, 14pt of slack stops discriminating: a slow scroll
            // covers about 11pt in that time and would have been recognised as
            // a hold, taking the scroll with it (see suspendCompanions).
            press.allowableMovement = 10
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
                suspendCompanions()
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
            // Runs before the `isTracking` guard: a press that was suspended
            // and then cancelled must still give the page its gestures back.
            resumeCompanions()
            guard isTracking else { return }
            isTracking = false
            onEnded()
        }

        /// Where a press is turned down: while anything is presented over the
        /// app, inside a rect that has its own meaning for being held, or
        /// anywhere over a text input.
        func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
            let window = (gesture.view as? UIWindow) ?? gesture.view?.window
            if isPresentingModally(window) { return false }
            let point = gesture.location(in: gesture.view)
            if exclusions.contains(where: { $0.contains(point) }) { return false }
            return !isOverTextInput(point, in: gesture.view)
        }

        /// A SHEET IS NOT SOMEWHERE THE LAUNCHER EXISTS.
        ///
        /// The recogniser lives on the window, which is the whole reason it
        /// works over every layer `RootView` draws - and the same reason it
        /// kept working under layers RootView does not draw. A presented
        /// controller (Journal compose, the Ask document popup, a Documents
        /// share or preview, the Settings contact card) sits in its own view
        /// hierarchy above the root's, but touches still pass through the
        /// window on their way there. So a hold inside a sheet opened the fan
        /// invisibly behind it, fired its haptics, and routed `presentedTile`
        /// underneath on release: the user let go of a modal and found the app
        /// on a different page.
        ///
        /// Asked here rather than plumbed through as a per-sheet flag, because
        /// the flag has to be right at every one of those call sites and a
        /// sheet added later would silently start the bug again. The window
        /// already knows the answer.
        ///
        /// Recursive rather than `rootViewController?.presentedViewController`:
        /// SwiftUI presents from whichever hosting controller owns the view
        /// that carries the `.sheet`, which inside a `NavigationStack` is a
        /// descendant of the root and not the root itself.
        private func isPresentingModally(_ window: UIWindow?) -> Bool {
            guard let root = window?.rootViewController else { return false }
            return presents(root)
        }

        private func presents(_ controller: UIViewController) -> Bool {
            if controller.presentedViewController != nil { return true }
            return controller.children.contains(where: presents)
        }

        /// A field being *edited* is never the launcher's to take.
        ///
        /// Holding one is how iOS offers the magnifier and selection, and
        /// cancelling that touch is how you end up with a field that will not
        /// take focus. But this used to stand aside for every text input on
        /// screen, edited or not, and on a screen that is mostly input rows —
        /// the daily plan, with its two "add" fields — that turned the
        /// launcher off exactly where a thumb naturally lands. An idle field
        /// has no selection to magnify and nothing to lose by the launcher
        /// taking a long press; tapping it first still focuses it, and from
        /// then on holding means what it means everywhere else in iOS.
        private func isOverTextInput(_ point: CGPoint, in view: UIView?) -> Bool {
            guard let hit = view?.hitTest(point, with: nil) else { return false }
            var responder: UIResponder? = hit
            while let current = responder {
                if current is UITextView || current is UITextField {
                    return current.isFirstResponder
                }
                responder = current.next
            }
            return false
        }

        /// Shares the screen right up until the press is recognised, and not a
        /// moment after.
        ///
        /// Returning `true` unconditionally is what let a sweep scroll the page
        /// underneath the open fan: simultaneous recognition stays in force for
        /// the life of the gesture, so the scroll view's pan kept following the
        /// same finger that was choosing a destination. Before recognition the
        /// answer must stay `true` — lists have to keep scrolling and buttons
        /// have to keep taking taps during the 0.22s nobody has committed to
        /// anything yet.
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            if isTracking { return false }
            companions.add(other)
            return true
        }

        /// Recognisers that asked to run alongside this one, held weakly: they
        /// belong to screens that come and go, and this object outlives them.
        private let companions = NSHashTable<UIGestureRecognizer>.weakObjects()
        private var suspended: [UIGestureRecognizer] = []

        /// Takes the other recognisers out of the gesture entirely.
        ///
        /// Declining simultaneous recognition stops one that has not started;
        /// this is for one that already has. A scroll begun in the moment
        /// before the press was recognised would otherwise carry on under the
        /// fan, and toggling `isEnabled` is UIKit's own way of cancelling a
        /// gesture in flight.
        private func suspendCompanions() {
            for other in companions.allObjects where other.isEnabled {
                other.isEnabled = false
                suspended.append(other)
            }
        }

        private func resumeCompanions() {
            for other in suspended { other.isEnabled = true }
            suspended.removeAll()
        }
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
