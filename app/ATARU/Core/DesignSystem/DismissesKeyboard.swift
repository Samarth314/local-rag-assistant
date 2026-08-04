import SwiftUI

/// Tap here to put the keyboard away — without stealing any other gesture.
///
/// The screen used to carry an explicit "Done" button on the keyboard
/// accessory bar. It was the wrong shape twice over: on iOS 26 that bar draws
/// as a bare unlabelled circle floating over the answer card, and a dedicated
/// dismiss control is redundant on a phone where tapping away from a field is
/// what everyone already does.
///
/// There WAS a catcher for that — a `Color.clear` under the content — but
/// being under the content is exactly why it never fired: the orb, the status
/// line and the answer cards are all hit-testable, so every tap "above the
/// keyboard" landed on one of them and never reached the layer beneath.
///
/// `simultaneousGesture` rather than an overlay or `onTapGesture` is the whole
/// trick: an overlay would swallow scrolling on the transcript, and a plain
/// tap gesture competes with the child's. A simultaneous tap runs alongside
/// whatever the child does, so the answer list still scrolls and the orb still
/// takes its press.
///
/// Deliberately NOT applied to the composer: a tap there has to place the
/// cursor, which is the one place dismissing would be wrong.
private struct DismissesKeyboard: ViewModifier {
    let active: Bool
    let dismiss: () -> Void

    func body(content: Content) -> some View {
        content.simultaneousGesture(
            TapGesture().onEnded { if active { dismiss() } },
            // Only in play while the keyboard is up, so nothing changes about
            // how the screen behaves the rest of the time.
            isEnabled: active
        )
    }
}

extension View {
    func dismissesKeyboard(when active: Bool,
                           _ dismiss: @escaping () -> Void) -> some View {
        modifier(DismissesKeyboard(active: active, dismiss: dismiss))
    }
}
