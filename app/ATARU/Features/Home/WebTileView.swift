import SafariServices
import SwiftUI

/// Opens one of ATARU's web pages inside the app.
///
/// Several tiles — Finances, Health, Personal, Canvas, the UI kit — exist as
/// pages on the server and have no native screen yet. Showing them greyed out
/// made the launcher honest but useless; opening the real page makes them
/// work today, and each one can be replaced by a native screen later without
/// the launcher changing.
///
/// `SFSafariViewController` rather than a bare `WKWebView`: it comes with a
/// readable address bar, Reader, sharing, and — the part that matters here —
/// its own cookie and data store, so nothing the app holds is exposed to the
/// page and nothing the page stores lands in the app's container.
struct WebTileView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let configuration = SFSafariViewController.Configuration()
        configuration.entersReaderIfAvailable = false
        let controller = SFSafariViewController(url: url, configuration: configuration)
        controller.preferredControlTintColor = UIColor(Theme.cyan)
        controller.dismissButtonStyle = .close
        return controller
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

/// Lets a URL drive `.sheet(item:)` directly.
///
/// The alternative is a parallel `isPresented` flag beside the URL, which can
/// disagree with it — a sheet showing with no URL, or a URL with no sheet.
extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}
