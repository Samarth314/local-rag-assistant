import Combine
import SwiftUI
import UIKit

/// How much of the screen the keyboard is currently covering, and how fast it
/// got there.
///
/// ## Why this is needed at all, when SwiftUI avoids the keyboard by itself
///
/// SwiftUI's automatic avoidance works by shrinking the safe area, and a view
/// that has been given an explicit height does not care what the safe area
/// does. `VoiceView` gives its layout exactly that - `.frame(height:
/// geo.size.height)` - because the Ask screen is a full-bleed column of
/// Spacers and fixed blocks that has to fill the screen rather than settle at
/// its natural height. The cost was that the column stayed full-screen tall
/// with the keyboard drawn over the bottom of it, which is why the composer
/// ended up behind the keyboard with a sliver showing.
///
/// Rather than fight the automatic behaviour, that screen opts out of it
/// (`.ignoresSafeArea(.keyboard)`) so the geometry stays stable and
/// orientation-correct, and subtracts THIS measurement instead. Explicit beats
/// implicit when the implicit thing has already been overridden.
///
/// Measured from the keyboard's real frame, so it is right in both
/// orientations and for every keyboard height - floating, split, with or
/// without a predictive bar - rather than assuming a number.
final class KeyboardInset: ObservableObject {

    /// Points of the app's own safe area the keyboard is covering. Zero when
    /// the keyboard is down.
    @Published private(set) var overlap: CGFloat = 0
    /// The system's own animation duration for the current transition. Matching
    /// it is what makes the composer travel WITH the keyboard instead of
    /// arriving after it.
    @Published private(set) var duration: Double = 0.25

    private var observers: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        // Both delivered on the main queue, which is where @Published has to be
        // written from - hence `queue: .main` rather than a hop of our own.
        observers.append(center.addObserver(
            forName: UIResponder.keyboardWillChangeFrameNotification,
            object: nil, queue: .main) { [weak self] note in
                self?.apply(note)
            })
        observers.append(center.addObserver(
            forName: UIResponder.keyboardWillHideNotification,
            object: nil, queue: .main) { [weak self] note in
                self?.duration = Self.duration(of: note)
                self?.overlap = 0
            })
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    private func apply(_ note: Notification) {
        duration = Self.duration(of: note)
        guard let end = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey]
                         as? NSValue)?.cgRectValue,
              let window = ActiveWindow.current else {
            overlap = 0
            return
        }
        let covered = window.bounds.maxY - end.minY
        // Reduced by the bottom safe-area inset, because the layout this feeds
        // already sits inside it. Counting the home indicator twice lifts the
        // composer 34pt higher than the keyboard for no reason.
        overlap = max(0, covered - window.safeAreaInsets.bottom)
    }

    private static func duration(of note: Notification) -> Double {
        let value = note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double
        // A zero duration arrives on a hardware-keyboard change and would make
        // the layout snap.
        return (value ?? 0) > 0 ? value! : 0.25
    }
}
