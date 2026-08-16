import UIKit

/// The window the app is actually being used in, and what it can tell us about
/// the shape of the screen right now.
///
/// Pulled out of `KeyboardInset`, which had this lookup private and is not the
/// only thing that needs it: any measurement expressed in GLOBAL coordinates -
/// where the top of the screen is 0 and the status bar is real - has to know
/// how much of the top belongs to the system rather than to the app, and that
/// number is different in portrait and landscape on the same device.
enum ActiveWindow {

    /// The key window of the foreground scene, or the best available stand-in
    /// during launch and backgrounding.
    static var current: UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let active = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        return active?.windows.first { $0.isKeyWindow } ?? active?.windows.first
    }

    /// Points at the top of the screen that belong to the system: the status
    /// bar, and the notch or Dynamic Island where there is one.
    ///
    /// ORIENTATION-DEPENDENT, which is the whole point of asking rather than
    /// assuming. On a modern iPhone it is 59pt in portrait and 0 in landscape,
    /// because the island moves to the side and takes the status bar with it.
    /// A layout constant derived from the portrait figure is therefore wrong by
    /// its entire value on a phone lying on its side.
    static var topInset: CGFloat { current?.safeAreaInsets.top ?? 0 }
}
