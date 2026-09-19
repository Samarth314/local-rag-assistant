import SwiftUI
import UIKit

// MARK: - Making a number pad dismissable

/// The number pad is the one keyboard with no way off it.
///
/// Every other keyboard has a return key, so a field that ends with one is
/// self-dismissing and nobody notices the absence of anything else. `.numberPad`
/// and `.decimalPad` have neither a return key nor a hide-keyboard key, so a
/// screen that offers one and nothing else has trapped the keyboard: the pad
/// stays up over the content until something ELSE resigns first responder, and
/// on the Gym screens nothing did. "Tapping the bodyweight field brings up the
/// number pad; tapping outside does not dismiss it."
///
/// Three ways out, because they fail in different situations:
///
/// * **A tap anywhere that is not a text field**, which is this type. A
///   window-level recogniser rather than a SwiftUI gesture or a `Color.clear`
///   catcher: the catcher was tried already elsewhere in this app and never
///   fired, because everything on a card is hit-testable, so the tap lands on
///   content and never reaches a layer underneath. A recogniser on the window
///   sees the touch before the view hierarchy does and, with
///   `cancelsTouchesInView = false`, passes it on untouched - buttons still
///   press, rows still tap, scrolls still scroll.
/// * **A `Done` bar above the pad**, declared once per screen in
///   `dismissableNumberPads`. Discoverable, reachable with the thumb that is
///   already down there, and the answer when the content fills the screen and
///   there is no empty space left to tap.
/// * **Dragging the page**, via `scrollDismissesKeyboard(.interactively)`.
///
/// The delegate is what makes the first one safe. A tap that lands on a text
/// input is refused outright, so tapping from one field straight into the next
/// does not resign the keyboard out from under the field being tapped - which
/// is the classic way this trick goes wrong, and is worse than the bug it
/// fixes.
///
/// PRIVACY: this file reads no field's text, ever. It resigns first responder
/// and nothing else; the values in those fields are health-class data
/// (weights, reps, bodyweight) and nothing here touches them.
private final class NumberPadSupport: NSObject, UIGestureRecognizerDelegate {

    /// One per attaching view, so a screen going away takes its recogniser
    /// with it rather than leaving one on the window forever.
    private weak var window: UIWindow?
    private var tap: UITapGestureRecognizer?

    // MARK: Attaching

    func attach(to window: UIWindow) {
        guard self.window !== window else { return }
        detach()
        self.window = window

        let recognizer = UITapGestureRecognizer(target: self,
                                                action: #selector(handleTap))
        // A recogniser that cancels touches would eat the tap it is passing
        // through, and every button on the page would stop working while the
        // keyboard was up.
        recognizer.cancelsTouchesInView = false
        recognizer.delaysTouchesBegan = false
        recognizer.delaysTouchesEnded = false
        recognizer.delegate = self
        window.addGestureRecognizer(recognizer)
        tap = recognizer
    }

    func detach() {
        if let tap, let window { window.removeGestureRecognizer(tap) }
        tap = nil
        window = nil
    }

    deinit { detach() }

    // MARK: Dismissing

    @objc private func handleTap() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                        to: nil, from: nil, for: nil)
    }

    // MARK: Delegate

    func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                           shouldReceive touch: UITouch) -> Bool {
        // Nothing to do when no keyboard is up. Checked first so the common
        // case costs one property read.
        guard let window, Self.isEditing(in: window) else { return false }
        guard let view = touch.view else { return true }
        return !Self.isTextInput(view)
    }

    func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }

    /// True when the touched view is a text field, a text view, or lives
    /// inside one.
    ///
    /// The ancestor walk matters: a `UITextField` is several views deep by the
    /// time a touch lands on the label that draws its text, and answering
    /// "not a text input" there is exactly the case that resigns the keyboard
    /// out from under the field the user is tapping into.
    static func isTextInput(_ view: UIView) -> Bool {
        var current: UIView? = view
        while let candidate = current {
            if candidate is UITextField || candidate is UITextView { return true }
            current = candidate.superview
        }
        return false
    }

    private static func isEditing(in window: UIWindow) -> Bool {
        firstResponder(in: window) != nil
    }

    private static func firstResponder(in view: UIView) -> UIResponder? {
        if view.isFirstResponder { return view }
        for child in view.subviews {
            if let found = firstResponder(in: child) { return found }
        }
        return nil
    }
}

/// Invisible, and exists only to reach the window - the same trick
/// `PressAnywhere` uses, and for the same reason: a recogniser has to hang off
/// something that outranks the view hierarchy it is watching.
private struct NumberPadDismissal: UIViewRepresentable {

    func makeUIView(context: Context) -> UIView {
        AttachingView(support: context.coordinator)
    }

    func updateUIView(_ view: UIView, context: Context) {}

    func makeCoordinator() -> NumberPadSupport { NumberPadSupport() }

    static func dismantleUIView(_ view: UIView, coordinator: NumberPadSupport) {
        coordinator.detach()
    }

    final class AttachingView: UIView {
        private let support: NumberPadSupport

        init(support: NumberPadSupport) {
            self.support = support
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            backgroundColor = .clear
        }

        required init?(coder: NSCoder) { fatalError("unused") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let window { support.attach(to: window) } else { support.detach() }
        }
    }
}

extension View {
    /// Every number pad under this view can be put away: by tapping off the
    /// field, by dragging the page, or with a Done bar above the keys.
    ///
    /// Applied at the top of a screen rather than to each field. A field does
    /// not know whether the page around it offers a way out, and the failure
    /// mode of forgetting one field is a keyboard the user cannot dismiss.
    func dismissableNumberPads() -> some View {
        background(NumberPadDismissal().frame(width: 0, height: 0))
            .scrollDismissesKeyboard(.interactively)
            // Declared ONCE per screen, not once per field. SwiftUI merges
            // every keyboard toolbar in the hierarchy into one bar, so a
            // declaration on each of the fourteen set rows would be
            // twenty-eight buttons fighting over it.
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        UIApplication.shared.sendAction(
                            #selector(UIResponder.resignFirstResponder),
                            to: nil, from: nil, for: nil)
                    }
                    .font(.ataruBody())
                    .foregroundStyle(Theme.cyan)
                    .accessibilityHint("Put the keyboard away.")
                }
            }
    }
}
