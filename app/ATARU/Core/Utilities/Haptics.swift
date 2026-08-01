import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Thin haptics wrapper that honours the user's in-app preference.
@MainActor
enum Haptics {
    static var isEnabled = true

    enum Event { case tap, success, warning, failure, selection }

    static func fire(_ event: Event) {
        guard isEnabled else { return }
        #if canImport(UIKit) && !targetEnvironment(macCatalyst)
        switch event {
        case .tap:
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .selection:
            UISelectionFeedbackGenerator().selectionChanged()
        case .success:
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .warning:
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        case .failure:
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
        #endif
    }
}
