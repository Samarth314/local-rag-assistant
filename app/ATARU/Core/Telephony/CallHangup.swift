import Foundation

/// What the server is told when the morning call stops.
///
/// ## Why the server needs to hear this at all
///
/// The redial ladder rings every fifteen minutes until he picks up AND speaks.
/// Until now the phone told the server exactly one thing: "I'm up", either by
/// voice or by the thumb button. Everything else - the red button, a decline
/// from the lock screen, a call that rang out into an empty room - was
/// invisible, and the ladder went on treating all three as silence.
///
/// They are not the same fact, and the difference is the one the ladder should
/// act on. Ending a call he answered is a deliberate hand on the phone. A
/// decline is also a deliberate hand, but a different intention. A call that
/// rang unanswered is evidence of nothing at all, which is precisely why the
/// ladder exists.
///
/// So this is a REPORT, not an instruction. The phone says what happened; the
/// server decides what the ladder does about it. Nothing here stands a redial
/// down - that is still `confirmMorningCall`, and only that.
enum CallHangupReason: String, Equatable, CaseIterable, Sendable {
    /// He answered and then hung up.
    case ended
    /// He declined it from the incoming screen without answering.
    case declined
    /// It rang and nobody touched it.
    case missed
}

/// The body of `POST /voip/hangup`, and the rules for deciding what goes in it.
///
/// Pure, and deliberately separate from `CallService`: the classification is
/// the part worth pinning down in tests, and the part that ships inside a
/// CallKit delegate is the part no test can reach.
enum CallHangup {

    /// How long a ringing call has to go untouched before an end action is
    /// read as a miss rather than as a decline.
    ///
    /// CallKit gives the app no way to tell the two apart: a decline from the
    /// lock screen and the system's own ring timeout both arrive as a bare
    /// `CXEndCallAction` with nothing on it that says which. Elapsed ring time
    /// is the only evidence there is, and it is decent evidence - a decline is
    /// a thumb that has already seen the screen, and twenty seconds is far
    /// past the point where someone who meant to refuse the call has refused
    /// it.
    ///
    /// Deliberately NOT implemented as a local timer that ends the call at the
    /// deadline. That would cut the ring short, and the whole point of the
    /// morning call is to go on ringing until it wakes him.
    static let declineWindow: TimeInterval = 20

    /// Classifies an ending that arrived with the call still ringing.
    ///
    /// `ringingSince` nil means this call never rang here (a call he placed,
    /// or one whose incoming moment was lost to a provider reset), and a
    /// decline is the conservative answer: it claims a hand on the phone,
    /// which is the weaker claim of the two for a ladder deciding whether to
    /// keep trying.
    static func endingForUnansweredCall(ringingSince: Date?,
                                        now: Date = Date()) -> CallEndReason {
        guard let ringingSince else { return .declined }
        return now.timeIntervalSince(ringingSince) >= declineWindow ? .missed : .declined
    }

    /// Whether this ending is worth telling the server about, and as what.
    ///
    /// Two gates, both of which have to pass:
    ///
    /// 1. **Only the morning call.** A call he placed from Recents is his own
    ///    business and has no ladder behind it. Reporting those would put a
    ///    stream of hangups in the server's morning record that have nothing
    ///    to do with any morning.
    /// 2. **Only the endings that are his.** A call displaced by the next
    ///    redial (`superseded`), a provider reset, and a failed transaction
    ///    are all the machinery moving, not a decision. Reporting a
    ///    `superseded` call as "ended" would tell the server he hung up on a
    ///    call that the ladder itself took away - which is a lie about the one
    ///    signal the ladder reads.
    static func report(for ending: CallEndReason,
                       isMorningCall: Bool) -> CallHangupReason? {
        guard isMorningCall else { return nil }
        switch ending {
        case .hungUp:   return .ended
        case .declined: return .declined
        case .missed:   return .missed
        case .failed, .reset, .superseded: return nil
        }
    }

    /// `{"reason": ..., "at": ...}`, with `at` in local time carrying its
    /// offset.
    ///
    /// Local rather than UTC on purpose: the server's whole question is about
    /// a time of day in the house the phone is in, and the offset means
    /// nothing is being guessed at either end.
    struct Body: Encodable, Equatable {
        let reason: String
        let at: String
    }

    static func body(reason: CallHangupReason, at moment: Date) -> Body {
        Body(reason: reason.rawValue, at: timestamp(moment))
    }

    static func encode(reason: CallHangupReason, at moment: Date) throws -> Data {
        try JSONEncoder().encode(body(reason: reason, at: moment))
    }

    /// ISO 8601 with the phone's own offset, e.g. `2026-09-19T07:03:12-07:00`.
    static func timestamp(_ moment: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = .current
        return formatter.string(from: moment)
    }
}
