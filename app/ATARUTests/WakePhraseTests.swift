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
