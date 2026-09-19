import XCTest
@testable import ATARU

/// A backend that records what it was told about a call ending, and can be
/// made to fail a chosen number of times first.
private final class HangupStubService: ATARUService, @unchecked Sendable {
    /// How many attempts throw before one succeeds. The reporter takes one
    /// retry, so 1 is "recovered" and 2 is "gave up".
    var failuresBeforeSuccess = 0
    private(set) var attempts = 0
    private(set) var reported: [(reason: CallHangupReason, at: Date)] = []

    func checkStatus() async throws -> String? { "ok" }

    func documents(query: String?, category: DocumentCategory) async throws -> DocumentLibraryPage {
        .empty
    }

    func document(id: String) async throws -> IndexedDocument { throw APIError.notFound }

    func documentContent(id: String) async throws -> DocumentPayload { throw APIError.notFound }

    func ask(question: String) async throws -> SpokenAnswer {
        SpokenAnswer(text: "nothing to say", source: nil, audioURL: nil)
    }

    func vocabulary() async throws -> [String] { [] }

    func transcribe(samples: [Float]) async -> Transcription? { nil }

    func registerVoIPToken(_ token: String, environment: String) async throws {}

    func reportCallHangup(reason: CallHangupReason, at moment: Date) async throws {
        attempts += 1
        if attempts <= failuresBeforeSuccess { throw APIError.server(status: 503) }
        reported.append((reason, moment))
    }
}

/// What the phone tells the server when the morning call stops.
///
/// The CallKit delegate itself is out of reach of a test - `CXProvider` talks
/// to a system daemon - so the decisions it makes were deliberately pulled out
/// into `CallHangup`, and this is where they are argued with. The value of
/// that split is entirely here: a wrong answer in this table is a redial
/// ladder acting on a fact that never happened.
final class CallHangupClassificationTests: XCTestCase {

    func testAnsweredThenHungUpIsReportedAsEnded() {
        XCTAssertEqual(CallHangup.report(for: .hungUp, isMorningCall: true), .ended)
    }

    func testDeclinedIsReportedAsDeclined() {
        XCTAssertEqual(CallHangup.report(for: .declined, isMorningCall: true), .declined)
    }

    func testRingingOutIsReportedAsMissed() {
        XCTAssertEqual(CallHangup.report(for: .missed, isMorningCall: true), .missed)
    }

    /// The gate that keeps the server's morning record about mornings.
    func testACallHePlacedIsNeverReported() {
        for ending: CallEndReason in [.hungUp, .declined, .missed, .reset, .superseded,
                                      .failed("nope")] {
            XCTAssertNil(CallHangup.report(for: ending, isMorningCall: false),
                         "\(ending) on a non-morning call must report nothing")
        }
    }

    /// The machinery moving is not a decision he made.
    ///
    /// `superseded` is the one that matters in practice: the ladder redials
    /// every fifteen minutes, and a redial landing on a call that is still
    /// nominally up retires the old one. Reporting that as "ended" would tell
    /// the server he hung up on a call the ladder itself took away.
    func testEndingsThatWereNotHisAreNotReported() {
        XCTAssertNil(CallHangup.report(for: .superseded, isMorningCall: true))
        XCTAssertNil(CallHangup.report(for: .reset, isMorningCall: true))
        XCTAssertNil(CallHangup.report(for: .failed("timed out"), isMorningCall: true))
    }

    func testEveryReasonHasOneFixedWireWord() {
        XCTAssertEqual(CallHangupReason.ended.rawValue, "ended")
        XCTAssertEqual(CallHangupReason.declined.rawValue, "declined")
        XCTAssertEqual(CallHangupReason.missed.rawValue, "missed")
        XCTAssertEqual(Set(CallHangupReason.allCases.map(\.rawValue)).count,
                       CallHangupReason.allCases.count)
    }
}

/// Telling a decline from a call that rang out, which CallKit will not do.
final class UnansweredCallTests: XCTestCase {

    func testAQuickEndIsADecline() {
        let rang = Date()
        XCTAssertEqual(
            CallHangup.endingForUnansweredCall(ringingSince: rang,
                                               now: rang.addingTimeInterval(3)),
            .declined)
    }

    func testRingingPastTheWindowIsAMiss() {
        let rang = Date()
        XCTAssertEqual(
            CallHangup.endingForUnansweredCall(
                ringingSince: rang,
                now: rang.addingTimeInterval(CallHangup.declineWindow + 1)),
            .missed)
    }

    func testTheWindowBoundaryItselfCountsAsAMiss() {
        let rang = Date()
        XCTAssertEqual(
            CallHangup.endingForUnansweredCall(
                ringingSince: rang,
                now: rang.addingTimeInterval(CallHangup.declineWindow)),
            .missed)
    }

    /// A call with no ringing moment never rang here. Declined is the weaker
    /// claim - it says a hand was on the phone - and the weaker claim is the
    /// right default for a ladder deciding whether to keep trying.
    func testACallThatNeverRangHereIsNotAMiss() {
        XCTAssertEqual(CallHangup.endingForUnansweredCall(ringingSince: nil), .declined)
    }

    func testAMissedCallIsNotLiveAndSaysSoOnScreen() {
        XCTAssertFalse(CallState.ended(.missed).isLive)
        XCTAssertEqual(CallState.ended(.missed).label, "Missed call")
        XCTAssertNotEqual(CallEndReason.missed.label, CallEndReason.declined.label)
    }
}

/// The body of `POST /voip/hangup`. This is the contract with the server, so
/// it is pinned by decoding what actually goes on the wire rather than by
/// re-reading the struct.
final class CallHangupPayloadTests: XCTestCase {

    private func decoded(_ reason: CallHangupReason, _ moment: Date) throws -> [String: String] {
        let data = try CallHangup.encode(reason: reason, at: moment)
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? [String: String])
    }

    func testTheBodyIsExactlyReasonAndAt() throws {
        let body = try decoded(.declined, Date())
        XCTAssertEqual(Set(body.keys), ["reason", "at"])
        XCTAssertEqual(body["reason"], "declined")
    }

    func testEveryReasonEncodesItsOwnWord() throws {
        for reason in CallHangupReason.allCases {
            XCTAssertEqual(try decoded(reason, Date())["reason"], reason.rawValue)
        }
    }

    /// Local time WITH its offset, which is the half that matters: the server
    /// is asking about a time of day in the house the phone is in, and a
    /// stamp without an offset makes that a guess at both ends.
    func testTheTimestampCarriesAnOffsetAndRoundTrips() throws {
        let moment = Date(timeIntervalSince1970: 1_789_000_000)
        let stamp = try XCTUnwrap(try decoded(.ended, moment)["at"])

        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime]
        let parsed = try XCTUnwrap(parser.date(from: stamp))
        // Whole seconds only on the wire, so allow the truncation.
        XCTAssertEqual(parsed.timeIntervalSince1970, moment.timeIntervalSince1970,
                       accuracy: 1.0)

        let tail = String(stamp.suffix(6))
        XCTAssertTrue(stamp.hasSuffix("Z") || tail.hasPrefix("+") || tail.hasPrefix("-"),
                      "\(stamp) carries no UTC offset")
    }

    func testTheStampIsTheMomentItWasGivenNotTheMomentItWasEncoded() {
        let moment = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(CallHangup.body(reason: .missed, at: moment).at,
                       CallHangup.timestamp(moment))
        XCTAssertNotEqual(CallHangup.timestamp(moment), CallHangup.timestamp(Date()))
    }
}

/// The reporter, against a stub backend. This is the "ending a call fires the
/// request" check: `CallStack` wires `CallService.onMorningCallEnded` straight
/// into `report`, so driving that closure is driving the call teardown's own
/// handoff.
@MainActor
final class MorningHangupReporterTests: XCTestCase {

    /// Polls rather than waiting on an expectation. The reporter's work is a
    /// main-actor task with a sleep in it, so a test that asserts the instant
    /// the stub is entered is asserting mid-flight - which is how a retry test
    /// reads the error state from the attempt before the one it meant.
    private func settles(within timeout: TimeInterval = 12,
                         _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    func testEndingAMorningCallSendsOneRequest() async {
        let service = HangupStubService()
        let reporter = MorningHangupReporter()
        reporter.update(service: service)

        let moment = Date(timeIntervalSince1970: 1_789_000_123)
        // Exactly what `CallStack` hangs off `onMorningCallEnded`.
        reporter.report(.ended, at: moment)

        let landed = await settles { !service.reported.isEmpty }
        XCTAssertTrue(landed, "ending a morning call must fire the request")
        XCTAssertEqual(service.attempts, 1)
        XCTAssertEqual(service.reported.map(\.reason), [.ended])
        XCTAssertEqual(service.reported.first?.at, moment)
        XCTAssertEqual(reporter.lastReported, .ended)
        XCTAssertNil(reporter.lastError)
    }

    func testAFailedReportIsRetriedExactlyOnce() async {
        let service = HangupStubService()
        service.failuresBeforeSuccess = 1
        let reporter = MorningHangupReporter()
        reporter.update(service: service)
        reporter.report(.missed)

        let recovered = await settles { !service.reported.isEmpty }
        XCTAssertTrue(recovered)
        XCTAssertEqual(service.attempts, 2)
        XCTAssertEqual(service.reported.map(\.reason), [.missed])
        XCTAssertNil(reporter.lastError)
    }

    /// A report that never lands costs nothing. The ladder's behaviour without
    /// it is the behaviour it had before any of this existed, so the only
    /// requirement is that it stops trying and says why.
    func testGivingUpLeavesTheReasonVisibleAndStopsTrying() async {
        let service = HangupStubService()
        service.failuresBeforeSuccess = 5
        let reporter = MorningHangupReporter()
        reporter.update(service: service)
        reporter.report(.declined)

        let gaveUp = await settles { reporter.lastError != nil && service.attempts == 2 }
        XCTAssertTrue(gaveUp)
        XCTAssertEqual(service.attempts, 2, "one attempt and one retry, never a loop")
        XCTAssertTrue(service.reported.isEmpty)
        XCTAssertEqual(reporter.lastReported, .declined)
    }

    func testWithNoBackendNothingIsSentAndNothingCrashes() {
        let reporter = MorningHangupReporter()
        reporter.report(.ended)
        XCTAssertNil(reporter.lastReported)
    }

    /// The default the protocol hands every other backend. A server without
    /// the route must not turn a hangup into an error on a path with no way
    /// to show one.
    func testABackendWithoutTheRouteAcceptsTheReportSilently() async throws {
        try await DemoATARUService().reportCallHangup(reason: .ended, at: Date())
    }
}

/// The alert push that arrives beside the morning ring, and the tap on it.
final class MorningCallAlertTests: XCTestCase {

    func testTheCategoryAloneRoutesToCallMode() {
        XCTAssertTrue(MorningCallAlert.wantsCall(category: MorningCallAlert.category,
                                                 userInfo: [:]))
    }

    func testTheUserInfoKeyAloneRoutesToCallMode() {
        XCTAssertTrue(MorningCallAlert.wantsCall(
            category: "",
            userInfo: [MorningCallAlert.actionKey: MorningCallAlert.actionValue]))
    }

    /// The server may put the key beside `aps` or inside it. Accepting both is
    /// what keeps the contract from depending on which.
    func testTheKeyNestedUnderApsAlsoRoutes() {
        XCTAssertTrue(MorningCallAlert.wantsCall(
            category: "",
            userInfo: ["aps": [MorningCallAlert.actionKey: MorningCallAlert.actionValue]]))
    }

    func testOtherNotificationsAreUntouched() {
        XCTAssertFalse(MorningCallAlert.wantsCall(category: RoutineReminders.category,
                                                  userInfo: [:]))
        XCTAssertFalse(MorningCallAlert.wantsCall(category: "", userInfo: [:]))
        XCTAssertFalse(MorningCallAlert.wantsCall(
            category: "", userInfo: [MorningCallAlert.actionKey: "health"]))
    }

    /// Byte for byte what the mini stamps. A category string that drifts by a
    /// character is a tap that opens the app and then sits there, with nothing
    /// anywhere saying why - which is the whole failure this alert exists to
    /// prevent, reintroduced one layer up.
    func testTheCategoryIsExactlyTheOneTheServerStamps() {
        XCTAssertEqual(MorningCallAlert.category, "ataru.morning.call")
        XCTAssertNotEqual(MorningCallAlert.category, RoutineReminders.category,
                          "two routed categories must not collide")
        XCTAssertEqual(MorningCallAlert.actionKey, "ataru_action")
        XCTAssertEqual(MorningCallAlert.actionValue, "call")
    }

    /// The tap and the VoIP push both land in the same latch, and the latch
    /// drains once. That is what stops an alert arriving beside a ring from
    /// stacking a second call.
    @MainActor
    func testATappedAlertAsksForExactlyOneCall() {
        _ = PendingCallRequest.take()   // clear anything a previous test left

        PendingCallRequest.record()
        PendingCallRequest.record()
        XCTAssertTrue(PendingCallRequest.take(), "the tap must reach call mode")
        XCTAssertFalse(PendingCallRequest.take(), "and only once")
    }

    @MainActor
    func testNoTapMeansNoCall() {
        _ = PendingCallRequest.take()
        XCTAssertFalse(PendingCallRequest.take())
    }
}
