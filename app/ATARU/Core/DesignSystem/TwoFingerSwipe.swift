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
/// The recogniser is set not to block anything else, so scrolling, buttons and
/// system edge gestures all keep working underneath it.
struct TwoFingerSwipe: UIViewRepresentable {
    var onUp: () -> Void
    var onDown: () -> Void

    func makeUIView(context: Context) -> UIView {
        // Transparent and non-interactive except for the recogniser, so it can
        // be laid over content without swallowing taps.
        let view = PassthroughView()
        for direction in [UISwipeGestureRecognizer.Direction.up, .down] {
            let swipe = UISwipeGestureRecognizer(
                target: context.coordinator,
                action: #selector(Coordinator.handle(_:))
            )
            swipe.numberOfTouchesRequired = 2
            swipe.direction = direction
            swipe.delegate = context.coordinator
            view.addGestureRecognizer(swipe)
        }
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.onUp = onUp
        context.coordinator.onDown = onDown
    }

    func makeCoordinator() -> Coordinator { Coordinator(onUp: onUp, onDown: onDown) }

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

        /// Never claims a gesture exclusively — the transcript still scrolls and
        /// the controls still take taps.
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool { true }
    }
}

/// A view that is invisible to hit-testing, so only its gesture recognisers see
/// touches and everything underneath behaves normally.
private final class PassthroughView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
}

extension View {
    /// Adds two-finger up and down swipes without disturbing anything else.
    func twoFingerSwipe(up: @escaping () -> Void, down: @escaping () -> Void) -> some View {
        overlay(TwoFingerSwipe(onUp: up, onDown: down).allowsHitTesting(true))
    }
}
