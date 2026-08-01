import Foundation

/// Removes credential-shaped strings before anything is logged, exported in a
/// diagnostics bundle, or shown in an error message.
///
/// This is deliberately high-precision: it matches token *shapes*, so ordinary
/// prose is never mangled.
enum SecretRedactor {

    private static let patterns: [(label: String, regex: NSRegularExpression)] = {
        let specs: [(String, String)] = [
            ("bearer", #"(?i)bearer\s+[A-Za-z0-9._\-]{8,}"#),
            ("api_key", #"sk-[A-Za-z0-9._\-]{12,}"#),
            ("token_field", #"(?i)"?(?:token|authorization|api[_-]?key|password|secret)"?\s*[:=]\s*"?[^\s",;}]{6,}"#),
            ("query_token", #"(?i)[?&](?:token|key|access_token)=[^&\s]+"#),
            ("jwt", #"eyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}"#)
        ]
        return specs.compactMap { label, pattern in
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            return (label, regex)
        }
    }()

    /// Returns `text` with every credential-shaped run replaced by a marker.
    static func redact(_ text: String) -> String {
        var output = text
        for (label, regex) in patterns {
            let range = NSRange(output.startIndex..., in: output)
            output = regex.stringByReplacingMatches(
                in: output, range: range, withTemplate: "[redacted:\(label)]"
            )
        }
        return output
    }

    /// Convenience for error surfaces.
    static func redact(_ error: Error) -> String { redact(String(describing: error)) }
}
