import Foundation

/// Errors surfaced to the UI. Each case maps to a distinct, useful message —
/// the app never shows a bare "Something went wrong".
enum APIError: LocalizedError, Equatable {
    case notConfigured
    case invalidURL
    case offline
    case timedOut
    case unauthorized
    case forbidden
    case notFound
    case server(status: Int)
    case malformedResponse(String)
    case cancelled
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "ATARU isn't connected yet. Add your server address in Settings, or stay in Demo mode."
        case .invalidURL:
            return "The configured server address can't be turned into a valid request URL."
        case .offline:
            return "No route to your ATARU server. Check that this device is on the Tailnet or LAN."
        case .timedOut:
            return "The server didn't respond in time. It may be asleep or busy loading a model."
        case .unauthorized:
            return "Your access token was rejected. Update it in Settings."
        case .forbidden:
            return "This endpoint refused the request — the agent may be permission-denied for this scope."
        case .notFound:
            return "That endpoint doesn't exist on your server. Check the API version in Settings."
        case .server(let status):
            return "Your ATARU server returned HTTP \(status)."
        case .malformedResponse(let detail):
            return "The response didn't match the expected shape (\(detail))."
        case .cancelled:
            return "Request stopped."
        case .transport(let detail):
            return "Network error: \(detail)"
        }
    }

    /// Maps a URLSession/Foundation error onto a domain error, redacting detail.
    static func from(_ error: Error) -> APIError {
        if error is CancellationError { return .cancelled }
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else {
            return .transport(SecretRedactor.redact(error))
        }
        switch nsError.code {
        case NSURLErrorCancelled: return .cancelled
        case NSURLErrorTimedOut: return .timedOut
        case NSURLErrorNotConnectedToInternet,
             NSURLErrorCannotFindHost,
             NSURLErrorCannotConnectToHost,
             NSURLErrorNetworkConnectionLost,
             NSURLErrorDNSLookupFailed:
            return .offline
        default:
            return .transport(SecretRedactor.redact(error))
        }
    }

    /// Maps an HTTP status code onto a domain error (nil for 2xx).
    static func from(statusCode: Int) -> APIError? {
        switch statusCode {
        case 200...299: return nil
        case 401: return .unauthorized
        case 403: return .forbidden
        case 404: return .notFound
        default: return .server(status: statusCode)
        }
    }
}
