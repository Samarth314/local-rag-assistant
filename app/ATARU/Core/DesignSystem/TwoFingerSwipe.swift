import SwiftUI
import UIKit

/// Recognises a two-finger swipe, which SwiftUI cannot express.
///
/// `DragGesture` reports where a drag went but never how many fingers made it,
/// so a two-finger gesture has to come from UIKit. It matters here because the
/// call screen is full of scrollable and tappable things: a one-finger swipe
/// already means "scroll the transcript", and overloading it would make
/// minimising fire whenever someone read a long answer.
///
/// ## Why the recognisers live on the window
///
/// A gesture recogniser only receives touches when *its own view* wins
/// hit-testing. The obvious implementation — an invisible overlay that returns
/// `nil` from `hitTest` so taps pass through — therefore never fires: passing
/// touches through and receiving them are mutually exclusive on one view. The
/// window is different: it is in the delivery path for every touch regardless
/// of which view wins, so recognisers attached there see all touches without
/// stealing any. `shouldRecognizeSimultaneouslyWith` keeps scrolling and taps
/// working underneath.
struct TwoFingerSwipe: UIViewRepresentable {
    var onUp: () -> Void
    var onDown: () -> Void

    func makeUIView(context: Context) -> UIView {
        AttachingView(coordinator: context.coordinator)
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.onUp = onUp
        context.coordinator.onDown = onDown
    }

    func makeCoordinator() -> Coordinator { Coordinator(onUp: onUp, onDown: onDown) }

    /// Invisible; exists to reach the window and hang the recognisers on it.
    final class AttachingView: UIView {
        private let coordinator: Coordinator
        private var attached: [UIGestureRecognizer] = []

        init(coordinator: Coordinator) {
            self.coordinator = coordinator
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            backgroundColor = .clear
        }

        required init?(coder: NSCoder) { fatalError("unused") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            // Moving between windows (or leaving one) always detaches first, so
            // a recogniser never outlives the view that owns its callbacks.
            attached.forEach { $0.view?.removeGestureRecognizer($0) }
            attached = []

            guard let window else { return }
            for direction in [UISwipeGestureRecognizer.Direction.up, .down] {
                let swipe = UISwipeGestureRecognizer(
                    target: coordinator, action: #selector(Coordinator.handle(_:)))
                swipe.numberOfTouchesRequired = 2
                swipe.direction = direction
                swipe.delegate = coordinator
                swipe.cancelsTouchesInView = false
                window.addGestureRecognizer(swipe)
                attached.append(swipe)
            }
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onUp: () -> Void
        var onDown: () -> Void

        init(onUp: @escaping () -> Void, onDown: @escaping () -> Void) {
            self.onUp = onUp
            self.onDown = onDown
        }

        @objc func handle(_ recognizer: UISwipeGestureRecognizer) {
            switch recognizer.direction {
            case .up: onUp()
            case .down: onDown()
            default: break
            }
        }

        /// Never claims a gesture exclusively — the transcript still scrolls
        /// and the controls still take taps.
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool { true }
    }
}

extension View {
    /// Adds two-finger up and down swipes without disturbing anything else.
    func twoFingerSwipe(up: @escaping () -> Void, down: @escaping () -> Void) -> some View {
        background(TwoFingerSwipe(onUp: up, onDown: down))
    }
}
