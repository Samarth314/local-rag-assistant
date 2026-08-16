import AVFoundation
import XCTest
@testable import ATARU

/// A backend that answers nothing and can be told to fail the one call these
/// tests care about.
private final class CallStubService: ATARUService, @unchecked Sendable {
    /// What `confirmMorningCall` does: throw (the 7am tailnet-not-up case),
    /// or report whether the server recorded it.
    var confirmError: Error?
    var confirmRecorded = true

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

    func transcribe(samples: [Float]) async -> String? { nil }

    func registerVoIPToken(_ token: String, environment: String) async throws {}

    @discardableResult
    func confirmMorningCall() async throws -> Bool {
        if let confirmError { throw confirmError }
        return confirmRecorded
    }
}

/// Covers the parts of the call feature that are pure logic.
///
/// The CallKit round trip itself is not unit-tested: `CXProvider` talks to a
/// system daemon, and a test that stubs it would only assert that the stub was
/// called. What *is* worth pinning down is the state machine, because the app
/// has no call UI of its own — CallKit draws everything — so this enum is the
/// only thing tracking whether a call exists, and a wrong answer here means
/// audio running with no call or a call with no audio.
final class CallStateTests: XCTestCase {

    func testOnlyLiveStatesCountAsLive() {
        XCTAssertTrue(CallState.dialing.isLive)
        XCTAssertTrue(CallState.incoming.isLive)
        XCTAssertTrue(CallState.active(connectedAt: Date()).isLive)

        XCTAssertFalse(CallState.idle.isLive)
        XCTAssertFalse(CallState.ended(.hungUp).isLive)
        XCTAssertFalse(CallState.ended(.failed("no route")).isLive)
    }

    /// `isLive` gates whether a new call can start, so a state that lies here
    /// leaves the app permanently unable to place one.
    func testEveryEndedStateReleasesTheLine() {
        for reason in [CallEndReason.hungUp, .declined, .reset, .failed("x")] {
            XCTAssertFalse(CallState.ended(reason).isLive,
                           "\(reason) should free the line for the next call")
        }
    }

    func testStateLabelsAreDistinct() {
        let labels = [
            CallState.dialing.label,
            CallState.incoming.label,
            CallState.active(connectedAt: Date()).label,
            CallState.ended(.hungUp).label
        ]
        XCTAssertEqual(Set(labels).count, labels.count, "each state needs its own label")
    }

    /// `.active` carries a timestamp, so equality has to compare it — two calls
    /// connected at different moments are not the same call.
    func testActiveEqualityIncludesConnectionTime() {
        let now = Date()
        XCTAssertEqual(CallState.active(connectedAt: now), .active(connectedAt: now))
        XCTAssertNotEqual(CallState.active(connectedAt: now),
                          .active(connectedAt: now.addingTimeInterval(1)))
    }

    /// A call displaced by an incoming one is over, and the line has to be
    /// free the instant it is - the replacement call is already arriving.
    func testSupersededReleasesTheLine() {
        XCTAssertFalse(CallState.ended(.superseded).isLive)
        XCTAssertEqual(CallState.ended(.superseded).label, "Call ended")
    }
}

// MARK: - The shared audio session

/// The hold-count contract, and the two players that were breaking it.
///
/// These are unit-testable because the counting is pure: `AudioSessionOwner`
/// only touches `AVAudioSession` on the drop to zero, after a five-second
/// linger that no test waits out. What is asserted here is the bookkeeping,
/// which is exactly where both bugs lived.
@MainActor
final class AudioSessionHoldTests: XCTestCase {

    override func setUp() {
        super.setUp()
        AudioSessionOwner.shared.reset()
    }

    override func tearDown() {
        AudioSessionOwner.shared.reset()
        super.tearDown()
    }

    /// `AnswerPlayer` never retained the session at all, so while it spoke the
    /// holder count was zero - and dictation's five-second release timer,
    /// which consults nothing else, deactivated the live call's session
    /// underneath it. On a call this player speaks the greeting, the goodbye
    /// and every error line.
    func testAnswerPlayerHoldsTheSessionWhileSpeaking() {
        let player = AnswerPlayer()
        player.managesAudioSession = false   // as it is during a call

        player.play(SpokenAnswer(text: "Good morning.", source: nil, audioURL: nil)) {}
        XCTAssertTrue(AudioSessionOwner.shared.inUse,
                      "playback must count as a user of the shared session")

        player.stop()
        XCTAssertFalse(AudioSessionOwner.shared.inUse,
                       "and must let go once it has stopped")
    }

    /// Every exit from `play` routes through `finish`, including the ones that
    /// never make a sound - an empty answer must not strand a hold either.
    func testAnswerPlayerReleasesOnAnEmptyAnswer() {
        let player = AnswerPlayer()
        player.managesAudioSession = false

        player.play(SpokenAnswer(text: "   ", source: nil, audioURL: nil)) {}
        XCTAssertFalse(AudioSessionOwner.shared.inUse)
    }

    /// THE HANG-UP BUG. `stop()` set `completion = nil` without calling it,
    /// and `CallSessionModel.speak` waits on that block inside a
    /// `withCheckedContinuation` - so ending a call mid-answer stranded `run()`
    /// forever, holding the session model, the dictation engine and both
    /// players with it.
    func testStoppingMidAnswerResumesTheWaiter() {
        let player = AnswerPlayer()
        player.managesAudioSession = false

        var finished = false
        player.play(SpokenAnswer(text: "A long answer.", source: nil, audioURL: nil)) {
            finished = true
        }
        XCTAssertFalse(finished, "not before it has been stopped")

        player.stop()
        XCTAssertTrue(finished, "hanging up mid-answer must release the caller")
    }

    /// A second answer replacing the first is the same strand by another
    /// route: `play` begins by calling `stop`.
    func testReplacingAnAnswerResumesThePreviousWaiter() {
        let player = AnswerPlayer()
        player.managesAudioSession = false

        var firstFinished = false
        player.play(SpokenAnswer(text: "First answer.", source: nil, audioURL: nil)) {
            firstFinished = true
        }
        player.play(SpokenAnswer(text: "Second answer.", source: nil, audioURL: nil)) {}
        XCTAssertTrue(firstFinished)

        player.stop()
        XCTAssertFalse(AudioSessionOwner.shared.inUse,
                       "and the hold must not have been doubled up")
    }

    /// `StreamingAnswerPlayer.begin` retained BEFORE four sites that can
    /// throw, and only `teardown` ever released - which cannot run, because it
    /// is gated on the `isActive` set on the method's last line. One failed
    /// `begin` pinned the count above zero for the life of the process, after
    /// which nothing would ever deactivate the session again.
    func testStreamingPlayerReleasesWhenBeginThrows() {
        let player = StreamingAnswerPlayer()
        player.managesAudioSession = false

        // An unbuildable format: the throw site just past the retain.
        XCTAssertThrowsError(try player.begin(sampleRate: 0, channels: 0))
        XCTAssertFalse(AudioSessionOwner.shared.inUse,
                       "a begin that threw must not leave a holder behind")
    }

    /// The counting itself, since both fixes lean on it: only the drop to zero
    /// releases, and a retain in between cancels nothing prematurely.
    func testOnlyTheLastUserOutReleasesTheSession() {
        AudioSessionOwner.shared.retain()
        AudioSessionOwner.shared.retain()
        AudioSessionOwner.shared.release()
        XCTAssertTrue(AudioSessionOwner.shared.inUse, "one user is still speaking")

        AudioSessionOwner.shared.release()
        XCTAssertFalse(AudioSessionOwner.shared.inUse)
    }
}

// MARK: - The conversation inside a call

@MainActor
final class CallSessionModelTests: XCTestCase {

    /// CallKit owns the session for the whole call, so every audio object the
    /// session model holds must be opted out of managing it. Dictation was the
    /// one that was not: it set `.playAndRecord`/`.spokenAudio` with
    /// `.defaultToSpeaker`, no Bluetooth and no echo cancellation, and
    /// activated - on the first turn of every call.
    func testNothingInACallManagesTheAudioSession() {
        let model = CallSessionModel(service: CallStubService())
        XCTAssertFalse(model.player.managesAudioSession)
        XCTAssertFalse(model.streamPlayer.managesAudioSession)
        XCTAssertFalse(model.dictation.managesAudioSession,
                       "the recogniser must not reconfigure CallKit's session")
    }

    /// An interruption holds the conversation; it does not end it. The flag is
    /// what the turn loop parks on.
    func testInterruptionParksAndReleases() {
        let model = CallSessionModel(service: CallStubService())

        model.setInterrupted(true)
        XCTAssertTrue(model.isInterrupted)
        XCTAssertEqual(model.phase, .idle)

        model.setInterrupted(false)
        XCTAssertFalse(model.isInterrupted)
    }

    /// A call that ended while interrupted must not leave the next one parked
    /// in a wait it can never leave.
    func testEndingClearsTheInterruption() {
        let model = CallSessionModel(service: CallStubService())
        model.setInterrupted(true)
        model.end()
        XCTAssertFalse(model.isInterrupted)
    }
}

// MARK: - "I'm up"

@MainActor
final class MorningConfirmTests: XCTestCase {

    /// THE DEAD END. A failed confirm swapped the button for static text with
    /// nothing to tap, and `phase` never returned to idle - so the one outcome
    /// that needs another attempt was the one outcome with no way to make it.
    /// At 7am against a tailnet that is not up yet, it is also the likeliest.
    func testAFailedConfirmStaysTappable() async {
        let service = CallStubService()
        service.confirmError = APIError.notFound
        let model = MorningConfirmModel()
        model.update(service: service)

        await model.confirm()

        XCTAssertEqual(model.phase, .failed)
        XCTAssertNil(model.acknowledgement,
                     "a failure settles nothing, so it must not replace the button")
        XCTAssertNotNil(model.failureMessage)
        XCTAssertTrue(model.isActionable)
        XCTAssertEqual(model.actionTitle, "Try again")
    }

    /// Re-attemptable indefinitely: the ladder is still ringing however many
    /// times the network has refused.
    func testRetryingAfterAFailureSucceeds() async {
        let service = CallStubService()
        service.confirmError = APIError.notFound
        let model = MorningConfirmModel()
        model.update(service: service)

        await model.confirm()
        XCTAssertEqual(model.phase, .failed)

        service.confirmError = nil
        await model.confirm()

        XCTAssertEqual(model.phase, .confirmed)
        XCTAssertTrue(model.isDone)
        XCTAssertNil(model.failureMessage)
        XCTAssertFalse(model.isActionable, "confirmed is the one state with nothing left to do")
    }

    /// "The server had no call in flight" is a settled answer, not a failure,
    /// and must not be dressed up as success either.
    func testNothingToConfirmIsAnAcknowledgementNotAnError() async {
        let service = CallStubService()
        service.confirmRecorded = false
        let model = MorningConfirmModel()
        model.update(service: service)

        await model.confirm()

        XCTAssertEqual(model.phase, .nothingToConfirm)
        XCTAssertNotNil(model.acknowledgement)
        XCTAssertNil(model.failureMessage)
        XCTAssertFalse(model.isDone)
    }
}
