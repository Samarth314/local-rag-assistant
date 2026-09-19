import SafariServices
import SwiftUI
import UIKit

/// A destination that is a web page ATARU deliberately does not draw itself.
///
/// `Identifiable` off the address rather than off a fresh UUID, so asking for
/// the same page twice is the same presentation rather than a second one.
struct SafariPage: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

/// `SFSafariViewController`, wrapped for SwiftUI.
///
/// ## Why not the embedded web view
///
/// `WebScreen` already exists and the Remote tile uses it, so a second web
/// surface wants a reason. The reason is passkeys.
///
/// A plain `WKWebView` inside an app cannot complete a WebAuthn ceremony
/// unless the app carries a `webcredentials:` associated-domain entitlement
/// for that host - the platform authenticator refuses to act for a web origin
/// the app has not been authorised to speak for. This app carries no
/// associated domains at all, so any passkey sign-in inside `WebScreen` fails
/// at the point the sheet should appear, with nothing on screen saying why.
///
/// `SFSafariViewController` runs out of process and shares Safari's own
/// credential store and its associated-domain relationships, so the passkey
/// works exactly as it does in Safari. It also carries the address bar, which
/// matters here for a second reason: the user can see which host they are
/// about to hand a credential to, and this app cannot read anything that
/// happens inside it - no cookies, no storage, no script injection.
///
/// So this is the correct wrapper for a sign-in-bearing site, and `WebScreen`
/// stays correct for the noVNC and DSM pages, which have no passkey and do
/// want to be framed as pages of the app.
struct SafariView: UIViewControllerRepresentable {
    let url: URL
    /// Called when Done is tapped. The caller clears its own state here: a
    /// controller embedded in a SwiftUI presentation does NOT dismiss itself,
    /// and without this the Done button reads as dead.
    let onFinish: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let configuration = SFSafariViewController.Configuration()
        // Both of these are for reading articles, and this is an app. Bar
        // collapsing in particular hides the address the page is served from
        // as soon as it is scrolled, which is the one thing worth keeping on
        // screen where a credential is about to be entered.
        configuration.entersReaderIfAvailable = false
        configuration.barCollapsingEnabled = false

        let controller = SFSafariViewController(url: url,
                                                configuration: configuration)
        controller.delegate = context.coordinator
        controller.dismissButtonStyle = .done
        controller.preferredControlTintColor = UIColor(Theme.cyan)
        controller.preferredBarTintColor = UIColor(Ataru.Palette.bg)
        return controller
    }

    /// Deliberately does not re-point an existing controller at a new URL:
    /// `SFSafariViewController` takes its address once, at init, and has no
    /// API to load another. A different page is a different presentation,
    /// which is what keying `SafariPage` on the address gives us.
    func updateUIViewController(_ controller: SFSafariViewController,
                                context: Context) {
        context.coordinator.onFinish = onFinish
    }

    final class Coordinator: NSObject, SFSafariViewControllerDelegate {
        var onFinish: () -> Void

        init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }

        func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
            onFinish()
        }
    }
}

/// Opens a URL in Safari itself, for the cases `SFSafariViewController` cannot
/// take.
///
/// It accepts http and https and nothing else - handed anything else it traps
/// rather than failing softly - so the scheme is checked before it is built
/// and everything else goes to the system. Today nothing reaches the fallback,
/// because the only external tile is an https one; it exists so that adding a
/// tile pointing at an app scheme is a routing change and not a crash.
enum ExternalPage {
    static func canPresentInApp(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "http", "https": return true
        default:              return false
        }
    }

    @MainActor
    static func openOutOfApp(_ url: URL) {
        UIApplication.shared.open(url)
    }
}
