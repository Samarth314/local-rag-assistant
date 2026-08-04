import SwiftUI
import WebKit

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

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // noVNC wants a real keyboard and clipboard; it also autoplays nothing,
        // so the only inline-media concession needed is the generic one.
        config.allowsInlineMediaPlayback = true
        let view = WKWebView(frame: .zero, configuration: config)
        view.isOpaque = false
        view.backgroundColor = .black
        view.scrollView.backgroundColor = .black
        // A remote desktop is a fixed-size surface: let it be pinched rather
        // than reflowed, which is what a VNC canvas actually needs on a phone.
        view.scrollView.bouncesZoom = true
        view.allowsBackForwardNavigationGestures = true
        view.load(URLRequest(url: url))
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        // Only reload on a genuine destination change - updateUIView fires on
        // every parent redraw, and reloading a live VNC session on each one
        // would drop the connection continuously.
        guard view.url?.absoluteString != url.absoluteString, !view.isLoading else { return }
        view.load(URLRequest(url: url))
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
