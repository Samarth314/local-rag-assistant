import XCTest
@testable import ATARU

/// A stub backend that answers instantly and records what it was asked.
private final class StubService: ATARUService, @unchecked Sendable {
    var answer = SpokenAnswer(text: "Snapshots run nightly.",
                              source: "records/work/policy.md", audioURL: nil)
    var error: Error?
    private(set) var questions: [String] = []

    func checkStatus() async throws -> String? { "ok" }

    func documents(query: String?, category: DocumentCategory) async throws -> DocumentLibraryPage {
        .empty
    }

    func document(id: String) async throws -> IndexedDocument { throw APIError.notFound }

    func documentContent(id: String) async throws -> DocumentPayload {
        throw APIError.notFound
    }

    func ask(question: String) async throws -> SpokenAnswer {
        questions.append(question)
        if let error { throw error }
        return answer
    }

    private(set) var registeredTokens: [(token: String, environment: String)] = []

    func registerVoIPToken(_ token: String, environment: String) async throws {
        registeredTokens.append((token, environment))
    }

    // No roster in tests: an empty vocabulary is the "bias nothing" case the
    // session already treats as normal.
    func vocabulary() async throws -> [String] { [] }
}

@MainActor
final class VoiceFlowTests: XCTestCase {

    func testAnsweringRecordsTheExchange() async throws {
        let service = StubService()
        let model = VoiceViewModel(service: service)

        model.ask("what is the backup policy")
        try await waitUntil { !model.exchanges.isEmpty }

        XCTAssertEqual(service.questions, ["what is the backup policy"])
        XCTAssertEqual(model.exchanges.first?.question, "what is the backup policy")
        XCTAssertEqual(model.exchanges.first?.answer, "Snapshots run nightly.")
    }

    func testNewestExchangeIsFirst() async throws {
        let service = StubService()
        let model = VoiceViewModel(service: service)

        model.ask("first")
        try await waitUntil { model.exchanges.count == 1 }
        model.ask("second")
        try await waitUntil { model.exchanges.count == 2 }

        XCTAssertEqual(model.exchanges.map(\.question), ["second", "first"])
    }

    func testFailureSurfacesAMessageAndStaysAskable() async throws {
        let service = StubService()
        service.error = APIError.offline
        let model = VoiceViewModel(service: service)

        model.ask("anything")
        try await waitUntil { if case .failed = model.phase { return true }; return false }

        guard case .failed(let message) = model.phase else { return XCTFail("expected failure") }
        XCTAssertFalse(message.isEmpty)
        // A failed question must not strand the UI — the user can ask again.
        XCTAssertTrue(model.phase.allowsNewQuestion)
    }

    func testTypedQuestionIsTrimmedAndBlankIsIgnored() async throws {
        let service = StubService()
        let model = VoiceViewModel(service: service)

        model.typedQuestion = "   "
        model.submitTypedQuestion()
        XCTAssertTrue(service.questions.isEmpty)

        model.typedQuestion = "  what renews soon  "
        model.submitTypedQuestion()
        try await waitUntil { !service.questions.isEmpty }
        XCTAssertEqual(service.questions, ["what renews soon"])
        XCTAssertEqual(model.typedQuestion, "")
    }

    func testPhaseGatesNewQuestionsWhileBusy() {
        XCTAssertTrue(VoicePhase.idle.allowsNewQuestion)
        XCTAssertTrue(VoicePhase.failed("x").allowsNewQuestion)
        XCTAssertFalse(VoicePhase.thinking.allowsNewQuestion)
        XCTAssertFalse(VoicePhase.speaking.allowsNewQuestion)
        XCTAssertFalse(VoicePhase.listening.allowsNewQuestion)
    }

    /// Polls until `condition` holds. Used instead of a fixed sleep so the
    /// tests aren't timing-dependent on a loaded machine.
    private func waitUntil(timeout: TimeInterval = 3,
                           _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("condition not met within \(timeout)s"); return }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

final class DemoServiceTests: XCTestCase {

    func testDemoFixturesCarryNoRealPersonalData() {
        // The fixtures ship in the binary; they must stay synthetic.
        let joined = DemoFixtures.documents()
            .map { "\($0.title) \($0.path) \($0.excerpt)" }
            .joined(separator: " ")
        for forbidden in ["Samarth", "@gmail", "SSN", "555-", "4111"] {
            XCTAssertFalse(joined.contains(forbidden), "fixture leaked \(forbidden)")
        }
    }

    func testDemoAnswersTrackTheQuestionAsked() {
        let (backup, _) = DemoFixtures.answer(for: "what is the backup policy")
        let (subs, _) = DemoFixtures.answer(for: "which subscriptions renew")
        XCTAssertNotEqual(backup, subs)
    }

    func testEmptyQuestionGetsAUsefulReply() {
        let (text, source) = DemoFixtures.answer(for: "")
        XCTAssertTrue(text.contains("didn't catch"))
        XCTAssertNil(source)
    }

    func testAnUnsupportedTypeExistsSoThatStateIsReachable() {
        XCTAssertTrue(DemoFixtures.documents().contains { !$0.previewable })
    }
}
