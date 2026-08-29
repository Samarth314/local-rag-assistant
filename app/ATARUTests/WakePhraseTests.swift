import XCTest
@testable import ATARU

/// The whole judgement behind "Hey ATARU", tested as arithmetic.
///
/// Two failure modes matter and they are opposites. A wake word that misses is
/// a feature that does not exist - and it WILL miss, because Apple's recogniser
/// has never seen the word "ATARU" and writes down the nearest thing it knows.
/// A wake word that over-fires opens the microphone in the middle of a
/// conversation nobody meant to have with a phone. Both are pinned here.
final class WakePhraseTests: XCTestCase {

    // MARK: - What must wake it

    func testHearsThePlainName() {
        XCTAssertTrue(WakePhrase.heard(in: "ATARU"))
        XCTAssertTrue(WakePhrase.heard(in: "ataru"))
        XCTAssertTrue(WakePhrase.heard(in: "Hey ATARU"))
        XCTAssertTrue(WakePhrase.heard(in: "hey ataru, what's on my calendar"))
    }

    func testHearsTheCommonMishearings() {
        // Every one of these is what a recogniser that does not know the word
        // actually writes down.
        XCTAssertTrue(WakePhrase.heard(in: "Hey a taru"))
        XCTAssertTrue(WakePhrase.heard(in: "hey Atari"))
        XCTAssertTrue(WakePhrase.heard(in: "Otaru, what time is it"))
        XCTAssertTrue(WakePhrase.heard(in: "at aru are you there"))
    }

    func testHearsTheMishearingsAddedAfterTheDeviceReport() {
        // The vowel at the end has no English anchor, so it is what the
        // recogniser guesses at.
        XCTAssertTrue(WakePhrase.heard(in: "Hey a taro"))
        XCTAssertTrue(WakePhrase.heard(in: "Ataro, what time is it"))
        XCTAssertTrue(WakePhrase.heard(in: "hey atara"))
        XCTAssertTrue(WakePhrase.heard(in: "A tarou, check my calendar"))
        // "hey" swallowing the leading "a" of the name.
        XCTAssertTrue(WakePhrase.heard(in: "Hey taru, what time is it"))
    }

    func testDoesNotAcceptMishearingsThatAreOrdinaryEnglish() {
        // All four ARE things the recogniser produces for this name, and all
        // four are things Arya could say in a room with the phone on the
        // table. A wake word that fires on them is worse than one that misses.
        XCTAssertFalse(WakePhrase.heard(in: "I finally got a tattoo"))
        XCTAssertFalse(WakePhrase.heard(in: "that is a true statement"))
        XCTAssertFalse(WakePhrase.heard(in: "we took a tour of the building"))
        XCTAssertFalse(WakePhrase.heard(in: "her flight lands in Ottawa"))
    }

    func testPunctuationAndCaseDoNotMatter() {
        XCTAssertTrue(WakePhrase.heard(in: "Hey, ATARU!"))
        XCTAssertTrue(WakePhrase.heard(in: "  hey   ATARU  "))
    }

    func testHearsItAtEitherEndOfAnUtterance() {
        XCTAssertTrue(WakePhrase.heard(in: "ataru what is my balance"))
        XCTAssertTrue(WakePhrase.heard(in: "okay so then I asked ataru"))
    }

    // MARK: - What must NOT wake it

    func testDoesNotFireInsideALongerWord() {
        // The whole reason the match is padded to word boundaries.
        XCTAssertFalse(WakePhrase.heard(in: "I went on safari last year"))
        XCTAssertFalse(WakePhrase.heard(in: "ataruism is not a word but this is one token"))
        XCTAssertFalse(WakePhrase.heard(in: "the notary called back"))
    }

    func testDoesNotFireOnOrdinarySpeech() {
        XCTAssertFalse(WakePhrase.heard(in: "what time does the train leave"))
        XCTAssertFalse(WakePhrase.heard(in: ""))
        XCTAssertFalse(WakePhrase.heard(in: "   "))
    }

    // MARK: - Normalisation

    func testNormalizeCollapsesEverythingButLettersAndDigits() {
        XCTAssertEqual(WakePhrase.normalize("Hey, ATARU -- what's up?"),
                       "hey ataru what s up")
        XCTAssertEqual(WakePhrase.normalize("   "), "")
    }

    // MARK: - The same-breath command
    //
    // The second field defect: "hey ataru check the time" said without a pause
    // used to lose everything after the name, because the phrase tore the
    // recogniser down and the command was spoken into the gap. The listener now
    // reads the command out of the SAME transcript, and this is that extraction.

    func testExtractsTheCommandSpokenInTheSameBreath() {
        let capture = WakePhrase.capture(in: "Hey ATARU, check the time")
        XCTAssertEqual(capture?.command, "check the time")
    }

    func testTheCommandKeepsTheSpeakersOwnWording() {
        // It becomes the question, so it must not arrive normalised.
        let capture = WakePhrase.capture(in: "hey ataru what's on Arya's calendar?")
        XCTAssertEqual(capture?.command, "what's on Arya's calendar?")
    }

    func testAPhraseWithNothingAfterItCapturesAnEmptyCommand() {
        // Not nil: the phrase WAS heard. Empty is what sends the turn down the
        // cue-and-listen path instead of asking immediately.
        XCTAssertEqual(WakePhrase.capture(in: "Hey ATARU")?.command, "")
        XCTAssertEqual(WakePhrase.capture(in: "Hey ATARU!  ")?.command, "")
    }

    func testNoPhraseMeansNoCapture() {
        XCTAssertNil(WakePhrase.capture(in: "what time does the train leave"))
        XCTAssertNil(WakePhrase.capture(in: ""))
    }

    func testTheCommandFollowsAMisheardNameToo() {
        XCTAssertEqual(WakePhrase.capture(in: "Hey a taru, turn the lamp on")?.command,
                       "turn the lamp on")
        XCTAssertEqual(WakePhrase.capture(in: "Atari how much did I spend")?.command,
                       "how much did I spend")
    }

    func testTheCommandFollowsTheFIRSTMentionOfTheName() {
        // A second "ataru" inside the question is part of the sentence, not a
        // new wake - splitting on the last one would ask "is listening".
        let capture = WakePhrase.capture(in: "hey ataru tell me when ataru is listening")
        XCTAssertEqual(capture?.command, "tell me when ataru is listening")
    }

    func testAnythingBeforeTheNameIsNotPartOfTheCommand() {
        let capture = WakePhrase.capture(in: "so anyway, ATARU, what is my balance")
        XCTAssertEqual(capture?.command, "what is my balance")
    }

    func testTheMatchReportsWhereThePhraseSits() {
        // The listener re-derives the command from a growing transcript on
        // every poll, so the match has to be a position, not a boolean.
        let match = WakePhrase.find(in: "hey ataru check the time")
        XCTAssertEqual(match, WakePhrase.Match(start: 1, end: 2, variant: "ataru"))
        // A two-word alias wins over the one-word one that starts inside it.
        XCTAssertEqual(WakePhrase.find(in: "hey a taru check the time"),
                       WakePhrase.Match(start: 1, end: 3, variant: "a taru"))
    }

    func testAGrowingTranscriptExtendsTheSameCommand() {
        // What the poll loop actually sees, partial by partial.
        let partials = [
            "hey",
            "hey ataru",
            "hey ataru check",
            "hey ataru check the",
            "hey ataru check the time",
        ]
        let commands = partials.map { WakePhrase.capture(in: $0)?.command }
        XCTAssertEqual(commands, [nil, "", "check", "check the", "check the time"])
    }
}

/// The stored-configuration path an App Intent depends on.
///
/// The intent runs with no `AppState` alive, so if this key or this decode ever
/// drifts, "Hey Siri, ask ATARU" starts answering from the build-time default
/// address instead of the one in Settings - and does it silently.
final class StoredConfigurationTests: XCTestCase {

    private var defaults: UserDefaults!
    private let suite = "ataru.tests.storedconfig"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
        super.tearDown()
    }

    func testFallsBackToTheDefaultWhenNothingIsStored() {
        XCTAssertEqual(AppConfiguration.stored(in: defaults), .default)
    }

    func testReadsBackWhatWasWrittenUnderTheSharedKey() throws {
        var saved = AppConfiguration.default
        saved.baseURLString = "https://ataru.example.ts.net"
        defaults.set(try JSONEncoder().encode(saved),
                     forKey: AppConfiguration.defaultsKey)

        let loaded = AppConfiguration.stored(in: defaults)
        XCTAssertEqual(loaded.baseURLString, "https://ataru.example.ts.net")
        XCTAssertEqual(loaded.baseURL?.host, "ataru.example.ts.net")
    }

    func testAGarbledBlobIsTheDefaultRatherThanACrash() {
        defaults.set(Data("not json".utf8), forKey: AppConfiguration.defaultsKey)
        XCTAssertEqual(AppConfiguration.stored(in: defaults), .default)
    }
}
