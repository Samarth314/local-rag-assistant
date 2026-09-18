import Foundation

/// The id of the conversation the phone is currently having.
///
/// The server used to mint one per WebSocket. That is only the same thing as
/// "per conversation" if the socket lives as long as the conversation, and it
/// does not: `VoiceStreamSession.ask` invalidates its task on any stream
/// failure — a receive-window timeout, an in-band `error` frame, an early
/// close — and the next question either reconnects or falls back to the
/// blocking `/voice/speak`. On 2026-09-11 one continuous half hour about
/// playing a home video on the TV became six server-side sessions plus two
/// turns carrying no session at all, and the assistant asked what "them"
/// referred to one turn after listing them.
///
/// So the phone owns the id instead. It is sent on every ask, survives
/// reconnects, app restarts and the switch between the streaming and blocking
/// paths, and rotates in exactly two cases:
///
///   * `startNew()` — the user deliberately starts a new chat.
///   * a gap of `idleWindow` since the last question. Yesterday evening is not
///     context for this morning, and the server's own history store expires on
///     the same window, so the two agree rather than race.
///
/// What is stored is an opaque identifier and a timestamp. No question, no
/// answer, nothing about what was said.
///
/// The server does not depend on this: absent the field it falls back to the
/// id this device used most recently, which fixes the reconnect case on its
/// own. What this adds is correctness across app restarts and an explicit
/// "new chat" the server cannot infer.
final class ConversationID: @unchecked Sendable {

    static let shared = ConversationID()

    /// Silence after which the next question starts a new conversation.
    /// Matches the server's `ATARU_CONV_IDLE_S` default.
    static let idleWindow: TimeInterval = 30 * 60

    private let idKey = "ataru.conversation.id"
    private let stampKey = "ataru.conversation.lastUsed"
    private let defaults: UserDefaults
    private let clock: @Sendable () -> Date
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard,
         clock: @escaping @Sendable () -> Date = { Date() }) {
        self.defaults = defaults
        self.clock = clock
    }

    /// The current conversation, rotated if it has gone stale. Calling this is
    /// what marks the conversation as still alive, so it is called once per
    /// question and not for background polling.
    func current() -> String {
        lock.lock()
        defer { lock.unlock() }
        let now = clock()
        let stored = defaults.string(forKey: idKey)
        let last = defaults.object(forKey: stampKey) as? Double ?? 0
        let stale = now.timeIntervalSince1970 - last > Self.idleWindow
        let id = (stored?.isEmpty == false && !stale) ? stored! : Self.mint()
        defaults.set(id, forKey: idKey)
        defaults.set(now.timeIntervalSince1970, forKey: stampKey)
        return id
    }

    /// Forget the current conversation. The next question opens a new one.
    @discardableResult
    func startNew() -> String {
        lock.lock()
        defer { lock.unlock() }
        let id = Self.mint()
        defaults.set(id, forKey: idKey)
        defaults.set(clock().timeIntervalSince1970, forKey: stampKey)
        return id
    }

    /// Hyphen-free and lowercase: the server sanitises identifiers off the
    /// wire to `[A-Za-z0-9_.:-]` and truncates, so a value that survives that
    /// untouched is one less thing that can differ between the two sides.
    private static func mint() -> String {
        "ios-" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
            .prefix(12).lowercased()
    }
}
