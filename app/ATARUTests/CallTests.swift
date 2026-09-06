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
    /// What `/api/morning/state` says. Default is the protocol's own
    /// `.inactive`, which is also what a server without the endpoint reports.
    var morningState: MorningCallState = .inactive

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

    func morningCallState() async throws -> MorningCallState { morningState }
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

    /// THE BUTTON'S GATE IS THE SERVER'S `can_confirm`, NOT THE CALL.
    ///
    /// The call screen used to draw it on `call.isMorningCall` alone, which is
    /// true for the whole call including after he has already spoken - so the
    /// control offered to end a ladder that had already stood down, and then
    /// sat in the header once the call was over.
    func testAConfirmedCallOffersNothing() async {
        let service = CallStubService()
        service.morningState = MorningCallState(inCallWindow: true,
                                                canConfirm: true, confirmed: true)
        let model = MorningConfirmModel()
        model.update(service: service)

        await model.refresh()

        XCTAssertFalse(model.isOffered)
        XCTAssertFalse(model.isPresented,
                       "a confirmed call must not leave a control anywhere")
    }

    func testAnOpenCallWindowWithNothingToConfirmOffersNothing() async {
        let service = CallStubService()
        // The window is open - the ladder may still be running - but the
        // server says there is nothing this thumb can settle.
        service.morningState = MorningCallState(inCallWindow: true,
                                                canConfirm: false, confirmed: false)
        let model = MorningConfirmModel()
        model.update(service: service)

        await model.refresh()

        XCTAssertFalse(model.isPresented)
    }

    func testAnOutstandingConfirmationIsOffered() async {
        let service = CallStubService()
        service.morningState = MorningCallState(inCallWindow: true,
                                                canConfirm: true, confirmed: false)
        let model = MorningConfirmModel()
        model.update(service: service)

        await model.refresh()

        XCTAssertTrue(model.isOffered)
        XCTAssertTrue(model.isPresented)
        XCTAssertTrue(model.isActionable)
    }

    /// ONE MODEL, SO ONE ANSWER. Two `@StateObject`s - one in VoiceView, one
    /// in CallSessionView - is what left the Ask page still offering to
    /// confirm a call the call screen had already confirmed. There is nothing
    /// to assert about "the other surface" any more: there is no other
    /// surface, and this pins the property that replaced it.
    func testConfirmingRetractsTheOfferEverywhereImmediately() async {
        let service = CallStubService()
        service.morningState = MorningCallState(inCallWindow: true,
                                                canConfirm: true, confirmed: false)
        let model = MorningConfirmModel()
        model.update(service: service)
        await model.refresh()
        XCTAssertTrue(model.isActionable)

        await model.confirm()

        XCTAssertTrue(model.isSettledLocally)
        XCTAssertFalse(model.isActionable,
                       "no surface may still invite a tap once one has landed")
        XCTAssertEqual(model.phase, .confirmed)
    }

    /// The optimistic hide is reverted by exactly one outcome, because it is
    /// the only one where the calls really do keep coming.
    func testAFailedConfirmPutsTheOfferBack() async {
        let service = CallStubService()
        service.morningState = MorningCallState(inCallWindow: true,
                                                canConfirm: true, confirmed: false)
        service.confirmError = APIError.notFound
        let model = MorningConfirmModel()
        model.update(service: service)
        await model.refresh()

        await model.confirm()

        XCTAssertFalse(model.isSettledLocally)
        XCTAssertTrue(model.isPresented)
        XCTAssertTrue(model.isActionable)
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

/// The end-of-turn decision, which is the difference between a call that
/// answers when you stop talking and one that sits there for twenty seconds.
///
/// Pure on purpose: `EndOfTurn.decide` takes the clock as an argument, so
/// every one of these cases is exact and none of them waits.
final class EndOfTurnTests: XCTestCase {

    private let start = ContinuousClock.now
    private var deadline: ContinuousClock.Instant {
        start + CallSessionModel.turnDeadline
    }

    private func decide(after elapsed: Duration,
                        lastVoiceAt: Duration? = nil,
                        transcript: String = "",
                        settledAt: Duration? = nil) -> TurnEnd {
        EndOfTurn.decide(now: start + elapsed,
                         deadline: deadline,
                         lastVoiceAt: lastVoiceAt.map { start + $0 },
                         transcript: transcript,
                         transcriptSettledAt: settledAt.map { start + $0 })
    }

    // MARK: - The level gate, unchanged

    func testNothingDecidesWhileTheCallerIsStillTalking() {
        XCTAssertEqual(decide(after: .seconds(3), lastVoiceAt: .seconds(3)),
                       .keepListening)
    }

    func testAQuietMicrophoneEndsTheTurnAfterTheGrace() {
        // 1.5s of silence is inside the pause in the middle of a sentence.
        XCTAssertEqual(decide(after: .milliseconds(4_500), lastVoiceAt: .seconds(3)),
                       .keepListening)
        XCTAssertEqual(decide(after: .milliseconds(4_700), lastVoiceAt: .seconds(3)),
                       .quiet)
    }

    // MARK: - The second signal

    /// The bug this gate was added for: a caller whose voice never crosses the
    /// level threshold used to run the full twenty seconds with the whole
    /// question already transcribed.
    func testASoftSpeakerEndsOnASettledTranscript() {
        XCTAssertEqual(decide(after: .milliseconds(2_500),
                              lastVoiceAt: nil,
                              transcript: "what time is it in india",
                              settledAt: .milliseconds(1_500)),
                       .settled)
    }

    func testASettledTranscriptEndsSoonerThanTheLevelGateEverCould() {
        // 900ms of stability beats the 1600ms silence grace, which is the
        // whole point of having a second signal.
        let settled = decide(after: .milliseconds(1_000),
                             transcript: "check my calendar",
                             settledAt: .milliseconds(0))
        XCTAssertEqual(settled, .settled)
    }

    func testStabilityAloneIsNotEnoughBeforeAWordLands() {
        XCTAssertEqual(decide(after: .seconds(5),
                              transcript: "",
                              settledAt: .milliseconds(100)),
                       .keepListening)
        XCTAssertEqual(decide(after: .seconds(5),
                              transcript: "   ",
                              settledAt: .milliseconds(100)),
                       .keepListening)
    }

    func testAFreshTranscriptIsNotASettledOne() {
        XCTAssertEqual(decide(after: .milliseconds(1_000),
                              transcript: "how much did i spend",
                              settledAt: .milliseconds(600)),
                       .keepListening)
    }

    /// The regression the old comment warns about: a recogniser that stalls
    /// while the caller is still audibly speaking must NOT read as an ending.
    /// The level gate is what proves somebody is still there.
    func testAStalledRecogniserUnderALoudCallerKeepsListening() {
        XCTAssertEqual(decide(after: .seconds(5),
                              lastVoiceAt: .milliseconds(4_800),
                              transcript: "when was the last time i got an email from",
                              settledAt: .milliseconds(2_000)),
                       .keepListening)
    }

    func testTheLevelGateWinsWhenBothWouldFire() {
        XCTAssertEqual(decide(after: .seconds(6),
                              lastVoiceAt: .seconds(3),
                              transcript: "turn the lamp on",
                              settledAt: .seconds(3)),
                       .quiet)
    }

    // MARK: - The ceiling

    func testTheHardDeadlineStillEndsASilentTurn() {
        XCTAssertEqual(decide(after: .seconds(19)), .keepListening)
        XCTAssertEqual(decide(after: CallSessionModel.turnDeadline), .deadline)
        XCTAssertEqual(decide(after: .seconds(25)), .deadline)
    }

    func testEveryReasonHasItsOwnFixedWordForTheLog() {
        let reasons = [TurnEnd.keepListening, .quiet, .settled, .deadline].map(\.reason)
        XCTAssertEqual(Set(reasons).count, reasons.count)
    }
}

/// The barge-in trigger: whether the microphone is hearing the caller cut in,
/// or ATARU hearing itself.
final class BargeInTests: XCTestCase {

    private let loud = CallSessionModel.voiceLevel + 0.2
    private let quiet = CallSessionModel.voiceLevel - 0.05

    func testTwoWordsOverTheLevelGateIsAnInterruption() {
        XCTAssertTrue(BargeIn.shouldInterrupt(partial: "no wait",
                                              level: loud,
                                              spokenSoFar: "Your next event is at four."))
    }

    func testOneWordIsNotEnough() {
        XCTAssertFalse(BargeIn.shouldInterrupt(partial: "no",
                                               level: loud,
                                               spokenSoFar: "Your next event is at four."))
    }

    func testWordsUnderTheLevelGateAreNotAnInterruption() {
        XCTAssertFalse(BargeIn.shouldInterrupt(partial: "no wait stop",
                                               level: quiet,
                                               spokenSoFar: "Your next event is at four."))
    }

    func testSilenceIsNotAnInterruption() {
        XCTAssertFalse(BargeIn.shouldInterrupt(partial: "",
                                               level: loud,
                                               spokenSoFar: "Your next event is at four."))
    }

    /// The failure mode the whole predicate exists to avoid: the answer coming
    /// back in through the microphone and stopping itself.
    func testTheAnswerEchoingBackIsNotAnInterruption() {
        XCTAssertFalse(BargeIn.shouldInterrupt(partial: "next event is",
                                               level: loud,
                                               spokenSoFar: "Your next event is at four."))
        XCTAssertFalse(BargeIn.shouldInterrupt(partial: "Your next event",
                                               level: loud,
                                               spokenSoFar: "Your next event is at four."))
    }

    /// Echo detection is contiguity, not a bag of words - a caller who reuses
    /// a word from the answer is still interrupting.
    func testReusingAWordFromTheAnswerIsStillAnInterruption() {
        XCTAssertTrue(BargeIn.shouldInterrupt(partial: "which event",
                                              level: loud,
                                              spokenSoFar: "Your next event is at four."))
        XCTAssertTrue(BargeIn.shouldInterrupt(partial: "no the other one",
                                              level: loud,
                                              spokenSoFar: "Your next event is at four."))
    }

    func testEchoIgnoresCaseAndPunctuation() {
        XCTAssertTrue(BargeIn.isEcho(BargeIn.words(in: "Next, event!"),
                                     of: "your next event is at four"))
    }

    func testMoreWordsThanWereEverSpokenCannotBeAnEcho() {
        XCTAssertFalse(BargeIn.isEcho(BargeIn.words(in: "one two three"), of: "one two"))
    }

    func testNothingHeardCountsAsEchoRatherThanSpeech() {
        XCTAssertTrue(BargeIn.isEcho([], of: "anything"))
    }

    func testTheGreetingCanBeTalkedOverToo() {
        XCTAssertTrue(BargeIn.shouldInterrupt(
            partial: "what's on my calendar",
            level: loud,
            spokenSoFar: "ATARU here. What would you like to know?"))
    }
}

/// The kill switch, and the migration hazard that comes with adding it.
final class BargeInConfigurationTests: XCTestCase {

    func testBargeInIsOnByDefault() {
        XCTAssertTrue(AppConfiguration.default.bargeIn)
    }

    /// A saved blob from before the key existed must decode, keep its server
    /// address, and default the switch on - NOT throw, which `stored()` would
    /// answer by silently resetting the phone to the built-in configuration.
    func testAConfigurationSavedBeforeTheSwitchExistedStillDecodes() throws {
        let legacy = """
        {"baseURLString":"https://ataru.example.ts.net","apiVersion":"",
         "requestTimeout":45,"persistsChatHistory":true,"hapticsEnabled":false,
         "mode":"live"}
        """
        let decoded = try JSONDecoder().decode(AppConfiguration.self,
                                               from: Data(legacy.utf8))
        XCTAssertEqual(decoded.baseURLString, "https://ataru.example.ts.net")
        XCTAssertEqual(decoded.requestTimeout, 45)
        XCTAssertFalse(decoded.hapticsEnabled)
        XCTAssertTrue(decoded.bargeIn)
    }

    func testTurningItOffSurvivesARoundTrip() throws {
        var configuration = AppConfiguration.default
        configuration.bargeIn = false
        let data = try JSONEncoder().encode(configuration)
        let decoded = try JSONDecoder().decode(AppConfiguration.self, from: data)
        XCTAssertFalse(decoded.bargeIn)
        XCTAssertEqual(decoded, configuration)
    }
}
