import Foundation

/// Validation result for a user-entered ATARU base URL.
enum BaseURLValidation: Equatable {
    case valid(URL)
    case empty
    case malformed
    case insecureScheme
    case missingHost

    var isValid: Bool { if case .valid = self { return true }; return false }

    var message: String? {
        switch self {
        case .valid: return nil
        case .empty: return "Enter the address of your ATARU server."
        case .malformed: return "That doesn't look like a URL. Example: https://ataru.your-tailnet.ts.net"
        case .missingHost: return "The URL needs a host, e.g. https://ataru.your-tailnet.ts.net"
        case .insecureScheme:
            return "Use https://. Plain http is only allowed for a LAN host in Debug builds."
        }
    }
}

/// Centralised, replaceable client configuration.
///
/// Everything a future backend might change — host, API version, timeouts — is
/// declared here rather than scattered through the feature code.
struct AppConfiguration: Equatable, Codable {
    var mode: AppEnvironmentMode
    var baseURLString: String
    var apiVersion: String
    var requestTimeout: TimeInterval
    var persistsChatHistory: Bool
    var hapticsEnabled: Bool

    static let `default` = AppConfiguration(
        mode: .demo,
        baseURLString: Bundle.main.object(forInfoDictionaryKey: "ATARUDefaultBaseURL") as? String ?? "",
        apiVersion: "",
        // Generous on purpose: a spoken answer is a retrieval plus a local
        // model plus Piper synthesis, which on a Jetson is several seconds
        // before the first byte. 30s was timing out legitimate answers.
        requestTimeout: 60,
        persistsChatHistory: true,
        hapticsEnabled: true
    )

    var baseURL: URL? {
        if case .valid(let url) = Self.validate(baseURLString) { return url }
        return nil
    }

    /// Validates a candidate base URL.
    ///
    /// HTTPS is required. A plain-`http` host is tolerated **only** in Debug
    /// builds and only for private/LAN-style hosts, so a release build can
    /// never be pointed at an unencrypted endpoint. See PRIVACY.md.
    static func validate(_ raw: String) -> BaseURLValidation {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased() else { return .malformed }
        guard let host = components.host, !host.isEmpty else { return .missingHost }
        guard let url = components.url else { return .malformed }

        switch scheme {
        case "https":
            return .valid(url)
        case "http":
            #if DEBUG
            return isPrivateHost(host) ? .valid(url) : .insecureScheme
            #else
            return .insecureScheme
            #endif
        default:
            return .malformed
        }
    }

    /// Private-range / link-local / `.local` hosts used on a home LAN.
    static func isPrivateHost(_ host: String) -> Bool {
        if host == "localhost" || host.hasSuffix(".local") || host.hasSuffix(".ts.net") { return true }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        switch (parts[0], parts[1]) {
        case (10, _): return true
        case (127, _): return true
        case (192, 168): return true
        case (172, 16...31): return true
        case (100, 64...127): return true   // CGNAT range used by Tailscale
        default: return false
        }
    }
}

/// Builds every endpoint URL from the configured base. Paths live here only.
///
/// The ATARU backend serves its routes at the root (`/documents`, `/voice/…`),
/// so `apiVersion` is empty by default. It is kept as a hook for a future
/// versioned deployment sitting behind a prefix; setting it inserts
/// `/api/<version>` ahead of every path.
struct EndpointBuilder {
    let baseURL: URL
    let apiVersion: String

    init(baseURL: URL, apiVersion: String = "") {
        self.baseURL = baseURL
        self.apiVersion = apiVersion
    }

    /// Joins `path` onto the base, preserving any base path prefix and
    /// appending query items. Returns nil if the result isn't a valid URL.
    func url(_ path: String, query: [URLQueryItem] = []) -> URL? {
        let cleanedPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        var base = baseURL.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        let prefix = apiVersion.isEmpty ? "" : "/api/\(apiVersion)"
        guard var components = URLComponents(string: "\(base)\(prefix)/\(cleanedPath)") else {
            return nil
        }
        if !query.isEmpty { components.queryItems = query }
        return components.url
    }

    // Documented client contract — see API_CONTRACT.md.

    var health: URL? { url("health") }

    func documents(query: String?, category: DocumentCategory) -> URL? {
        var items: [URLQueryItem] = []
        if let query, !query.isEmpty { items.append(URLQueryItem(name: "q", value: query)) }
        if category != .all { items.append(URLQueryItem(name: "category", value: category.rawValue)) }
        return url("documents", query: items)
    }

    /// Document ids are opaque server-assigned hashes, but they still go into
    /// a path segment, so they are percent-encoded rather than interpolated
    /// raw — a client must never be able to build `documents/../../etc`.
    func document(_ id: String) -> URL? { url("documents/\(Self.escape(id))") }
    func documentContent(_ id: String) -> URL? { url("documents/\(Self.escape(id))/content") }

    /// Spoken answer: WAV audio rendered in the same voice as the phone line.
    func speak(_ question: String) -> URL? {
        url("voice/speak", query: [URLQueryItem(name: "q", value: question)])
    }

    /// Text-only answer, used when the server has no voice engine.
    func answer(_ question: String) -> URL? {
        url("voice/answer", query: [URLQueryItem(name: "q", value: question)])
    }

    static func escape(_ component: String) -> String {
        component.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? component
    }
}
