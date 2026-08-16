import Foundation

extension URLSession {
    /// A session that writes nothing to disk, for anything that fetches vault
    /// content.
    ///
    /// `URLSession.shared` has an on-disk `URLCache`. `LiveATARUService`
    /// already refuses it - `config.urlCache = nil`, on the stated grounds
    /// that responses are vault content and should live only as long as the
    /// objects holding them - but the tile screens and the launcher health
    /// probe went out on `.shared`, and those responses are the same class of
    /// thing: the daily plan, health markers, finance rows, journal entries,
    /// the workspace list. They were being written into `~/Library/Caches` by
    /// Foundation, on a device that is not encrypted while it is unlocked.
    ///
    /// One session rather than one per caller, so the connection pool is
    /// shared the way `.shared` shared it.
    static let cacheless: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        // Per-request timeouts are set by the callers; this is the ceiling.
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()
}
