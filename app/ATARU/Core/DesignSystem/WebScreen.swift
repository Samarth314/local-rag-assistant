import SwiftUI
import UIKit
import WebKit

// MARK: - Warm web views

/// The app's web views, kept alive between visits instead of rebuilt on each.
///
/// Opening one of these used to cost a fresh `WKWebView` every time, and a
/// fresh `WKWebView` is a fresh web content process: process launch, then TLS,
/// then the page, then whatever the page does to authenticate — paid again on
/// every visit, even one you left ten seconds ago. Nothing about the second
/// visit is different from the first, so nothing about it should be slower
/// than reading a view out of a dictionary.
///
/// TWO CONSEQUENCES WORTH BEING DELIBERATE ABOUT.
///
/// The session survives. That is the point for DSM, which otherwise
/// re-authenticates on every visit, and it is also the point for noVNC: a
/// remote desktop you step away from should still be where you left it. It
/// does mean a VNC connection stays open after you navigate back, which is
/// why the cache is capped at exactly the number of machines the Remote page
/// offers rather than growing without limit.
///
/// The cookie store was ALREADY persistent — `WKWebViewConfiguration()`
/// defaults `websiteDataStore` to `.default()` — so re-login was never caused
/// by an ephemeral store, and swapping one in "for privacy" would silently
/// sign him out of every page. It is now set explicitly so that edit has to
/// be a deliberate one.
final class WarmWebViews {
    static let shared = WarmWebViews()

    /// Three machines on the Remote page, and that is the whole of the app's
    /// web surface. A fourth entry means a leak, not a cache.
    private let limit = 3
    private var views: [URL: WKWebView] = [:]
    private var order: [URL] = []

    /// Shared, so every web view starts from the same store and the same
    /// content-process pool. `WKWebView` copies its configuration at init, so
    /// handing the same instance to several views is safe.
    private let configuration: WKWebViewConfiguration = {
        let config = WKWebViewConfiguration()
        // noVNC wants a real keyboard and clipboard; it also autoplays nothing,
        // so the only inline-media concession needed is the generic one.
        config.allowsInlineMediaPlayback = true
        config.websiteDataStore = .default()
        return config
    }()

    func view(for url: URL) -> WKWebView {
        if let existing = views[url] {
            touch(url)
            return existing
        }
        let view = WKWebView(frame: .zero, configuration: configuration)
        // Transparent rather than black. A `.black` web view is #000000 and
        // the app's backdrop is a gradient running #15181D to #060708, so an
        // unpainted web view drew as a distinctly darker rectangle over it -
        // most visible at the top, where the backdrop is lightest, and for
        // exactly as long as the page took to first paint. Clear shows the
        // backdrop instead, so there is no rectangle to notice.
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        // What WebKit paints outside the page's own bounds - the rubber-band
        // overscroll, and any letterboxing around a fixed-size canvas like a
        // VNC framebuffer. Left unset it is white on a dark app.
        view.underPageBackgroundColor = UIColor(Ataru.Palette.bg)
        // A remote desktop is a fixed-size surface: let it be pinched rather
        // than reflowed, which is what a VNC canvas actually needs on a phone.
        view.scrollView.bouncesZoom = true
        view.allowsBackForwardNavigationGestures = true

        views[url] = view
        order.append(url)
        evictIfNeeded()
        return view
    }

    /// Build the web view - and therefore start its content process - without
    /// navigating, so a tap pays for the page and not for the process too.
    ///
    /// Deliberately does NOT begin loading. The Remote page's noVNC URLs carry
    /// `autoconnect=1`, so pre-loading them would open live sessions to the
    /// mini and the Orin merely because someone looked at the list of
    /// machines. Warming the process is free; warming the connection is not
    /// ours to decide.
    func prepare(_ url: URL) {
        _ = view(for: url)
    }

    /// Loads only when the destination actually changed. `updateUIView` fires
    /// on every parent redraw, and reloading a live VNC session on each one
    /// would drop the connection continuously.
    func load(_ view: WKWebView, _ url: URL) {
        guard view.url == nil || view.url?.absoluteString != url.absoluteString,
              !view.isLoading else { return }
        view.load(URLRequest(url: url))
    }

    private func touch(_ url: URL) {
        order.removeAll { $0 == url }
        order.append(url)
    }

    private func evictIfNeeded() {
        while order.count > limit, let oldest = order.first {
            order.removeFirst()
            // Stop it talking to the network on the way out; a cached view
            // that has been dropped should not still be pulling frames.
            views[oldest]?.stopLoading()
            views[oldest]?.removeFromSuperview()
            views[oldest] = nil
        }
    }
}

/// A web surface, shown inside the app rather than handed to Safari.
///
/// The app had no web view at all before this. It is added for exactly one
/// class of destination: the mini's browser-native tools that would be absurd
/// to reimplement in Swift - noVNC being the obvious one, since it *is* a
/// remote framebuffer client. Rewriting VNC natively to avoid a web view would
/// be worse in every way than embedding the one that already works.
///
/// Everything the app can answer from JSON stays native. This is not a licence
/// to wrap the dashboard.
///
/// Reachability is already handled: Info.plist sets `NSAllowsArbitraryLoads`,
/// which is what lets these tailnet hosts load at all (and note the warning
/// there - re-adding `NSAllowsLocalNetworking` silently breaks the 100.64/10
/// CGNAT range Tailscale uses).
struct WebScreen: UIViewRepresentable {
    let url: URL

    /// Start the content process for a destination before it is opened. Call
    /// it when the list of destinations appears; see `WarmWebViews.prepare`
    /// for why it stops short of loading the page.
    static func prepare(_ url: URL) {
        WarmWebViews.shared.prepare(url)
    }

    func makeUIView(context: Context) -> WKWebView {
        let view = WarmWebViews.shared.view(for: url)
        WarmWebViews.shared.load(view, url)
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        WarmWebViews.shared.load(view, url)
    }

    /// The view outlives this representable on purpose - it goes back to the
    /// cache, still loaded. Only the parenting is undone, or SwiftUI would
    /// hand it to the next host while it still claims a dead superview.
    static func dismantleUIView(_ view: WKWebView, coordinator: ()) {
        view.removeFromSuperview()
    }
}

/// A full-screen web destination with the app's own chrome around it.
struct WebDestination: View {
    let title: String
    let subtitle: String?
    let url: URL

    var body: some View {
        WebScreen(url: url)
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if let subtitle {
                    ToolbarItem(placement: .principal) {
                        VStack(spacing: 1) {
                            Text(title).font(.headline)
                            Text(subtitle)
                                .font(.caption2)
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
            }
    }
}
