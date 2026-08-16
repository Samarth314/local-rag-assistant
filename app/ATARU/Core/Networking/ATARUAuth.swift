import Foundation

/// The one place a request gets its credentials.
///
/// ## Why this exists
///
/// `LiveATARUService` has always sent the Keychain token — every method there
/// builds its request through `request(for:)`, POSTs included, and that stamps
/// `Authorization: Bearer`. So do `VoiceStreamSession` and `RemoteTranscriber`.
/// That is the assistant API, and it was never the problem.
///
/// The tile screens are the problem. `TileFetch` and the launcher health probe
/// build their own `URLRequest`s and send them bare, which is invisible while
/// the backend only *monitors* auth and becomes six broken screens the moment
/// it enforces it — Finance, Health, Home, Status, Journal, Workspaces, plus
/// the health dots. They talk to different hosts from the assistant base URL,
/// which is how they came to have their own fetcher and how the omission went
/// unnoticed.
///
/// ## Why the token is not sent everywhere
///
/// A bearer token is a credential, and stamping it onto whatever URL a caller
/// happens to pass is how credentials leak. The tile hosts are derived from
/// hardcoded ATARU domains today, so in practice every URL here is the user's
/// own infrastructure — but "in practice" is not a security property. The
/// token goes to the configured backend and to hosts inside the ATARU domain,
/// and to nothing else, so a URL that ever comes from somewhere less trusted
/// cannot carry it off the phone.
enum ATARUAuth {

    /// Reads the Keychain-backed token. Set once at launch by `AppState`;
    /// nil until then, and nil in Demo, where there is nothing to send.
    nonisolated(unsafe) static var tokenProvider: @Sendable () -> String? = { nil }

    /// Host of the server the app is configured to talk to. Set alongside the
    /// provider, and re-set whenever Settings changes the backend.
    nonisolated(unsafe) static var configuredHost: String?

    /// The domain the tile surfaces live under. Subdomains included: the tiles
    /// resolve to `home.`, `dash.` and `journal.` under this.
    static let ataruDomain = "ataru.aryasasikumar.com"

    static func configure(baseURL: URL?, tokenProvider: @escaping @Sendable () -> String?) {
        Self.tokenProvider = tokenProvider
        Self.configuredHost = baseURL?.host?.lowercased()
    }

    /// Whether this URL is allowed to receive the token.
    ///
    /// Pure and separately testable, because it is the whole of the security
    /// claim above and it should be possible to say so in a test rather than
    /// in a comment.
    static func isTrusted(_ url: URL, configuredHost: String?, domain: String = ataruDomain) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        // A fully-qualified name may carry a trailing root dot.
        let normalized = host.hasSuffix(".") ? String(host.dropLast()) : host
        if let configuredHost, normalized == configuredHost.lowercased() { return true }
        return normalized == domain || normalized.hasSuffix("." + domain)
    }

    /// Adds `Authorization: Bearer <token>` when there is a token to send and
    /// the destination is allowed to have it.
    ///
    /// The backend also accepts `X-Ataru-Token`; only one is sent, because two
    /// headers carrying one credential is two things to keep in step and the
    /// second buys nothing.
    static func stamp(_ request: inout URLRequest) {
        guard let url = request.url,
              isTrusted(url, configuredHost: configuredHost),
              let token = tokenProvider(), !token.isEmpty
        else { return }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
}
