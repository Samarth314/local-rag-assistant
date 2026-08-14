import SwiftUI

/// The three machines, each openable as a screen - in the app.
///
/// This replaced a single static card whose text was "noVNC screens for the
/// mini, Orin and NAS - a desktop-sized surface, best used from a desktop."
/// That was advice, not a feature: there was no way to reach any of them from
/// the phone, and the mini's hub has shipped exactly these three cards the
/// whole time.
///
/// noVNC opens in an embedded web view rather than natively, deliberately.
/// noVNC *is* a remote-framebuffer client; reimplementing VNC in Swift to
/// avoid a web view would be strictly worse than embedding the one that
/// already works and is already served on the tailnet. The NAS entry is
/// Synology DSM, which is a web UI and has no other form.
struct RemoteScreen: View {
    @StateObject private var health = TileHealthModel()

    /// Mirrors ~/srv/remote/web/index.html on the mini. The noVNC query string
    /// is copied from that page verbatim: autoconnect so the session opens
    /// without a second tap, resize=scale so a desktop fits a phone screen,
    /// and the quality/compression pair the hub already tuned for the tailnet.
    private struct Machine: Identifiable {
        let id: String
        let name: String
        let detail: String
        let symbol: String
        let path: String
    }

    private static let vncQuery =
        "autoconnect=1&resize=scale&shared=1&reconnect=1&quality=8&compression=1"

    private static let machines: [Machine] = [
        .init(id: "mini", name: "Mac mini", detail: "the always-on host",
              symbol: "macmini",
              path: "vnc.html?path=websockify%3Ftoken%3Dmini&\(vncQuery)"),
        .init(id: "orin", name: "Jetson Orin", detail: "models, voice, vision",
              symbol: "cpu",
              path: "vnc.html?path=websockify%3Ftoken%3Dorin&\(vncQuery)"),
        .init(id: "nas", name: "Synology NAS", detail: "DSM - storage and backups",
              symbol: "externaldrive.connected.to.line.below",
              path: "https://dsm.ataru.aryasasikumar.com"),
    ]

    private static let hub = "https://remote.ataru.aryasasikumar.com"

    private func url(for machine: Machine) -> URL? {
        machine.path.hasPrefix("http") ? URL(string: machine.path)
                                       : URL(string: "\(Self.hub)/\(machine.path)")
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Space.m) {
                if let up = health.upByKey[HomeTile.remote.launcherKey], !up {
                    ATCard {
                        Label("The remote hub isn't answering", systemImage: "xmark.circle")
                            .font(.ataruCaption())
                            .foregroundStyle(Theme.red)
                            .padding(Theme.Space.m)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                ForEach(Self.machines) { machine in
                    if let url = url(for: machine) {
                        NavigationLink {
                            WebDestination(title: machine.name,
                                           subtitle: machine.detail, url: url)
                        } label: {
                            row(machine)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(Theme.Space.screen)
        }
        .ataruBackdrop()
        .navigationTitle("Screens")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // Stand the web content processes up while the list is being read,
            // so opening a machine pays for the page and not for the process
            // too. This deliberately stops short of loading: these URLs carry
            // `autoconnect=1`, and looking at a list of machines should not
            // open live sessions to two of them. See `WarmWebViews.prepare`.
            for machine in Self.machines {
                if let url = url(for: machine) { WebScreen.prepare(url) }
            }
            await health.refresh()
        }
    }

    private func row(_ machine: Machine) -> some View {
        ATCard {
            HStack(spacing: Theme.Space.m) {
                Image(systemName: machine.symbol)
                    .font(.system(size: 26, weight: .ultraLight))
                    .foregroundStyle(Theme.cyan)
                    .frame(width: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(machine.name)
                        .font(.ataruLabel())
                        .foregroundStyle(Theme.textPrimary)
                    Text(machine.detail)
                        .font(.ataruCaption())
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.ataruCaption())
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(Theme.Space.l)
            .frame(maxWidth: .infinity)
        }
    }
}
