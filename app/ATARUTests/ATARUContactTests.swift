import XCTest
@testable import ATARU

/// The contact card, which is now a file rather than a write to the address
/// book.
///
/// The thing worth guarding is the reason the change was made at all: adding
/// ATARU to Contacts must not read the user's contacts. That is a claim about
/// what the code does NOT do, so it is asserted twice - here, on the shape of
/// what is produced, and in the source itself, where nothing imports Contacts.
final class ATARUContactTests: XCTestCase {

    func testTheCardIsAVCardIOSWillImport() {
        let card = ATARUContact.vCard(handle: "ataru")
        XCTAssertTrue(card.hasPrefix("BEGIN:VCARD\r\nVERSION:3.0"),
                      "iOS is fussiest about the opening lines")
        XCTAssertTrue(card.hasSuffix("END:VCARD\r\n"))
        // CRLF, not LF: the RFC says so and importers are inconsistent about
        // forgiving it.
        XCTAssertFalse(card.contains("\n\n"))
        XCTAssertTrue(card.contains("FN:ATARU"))
        XCTAssertTrue(card.contains("ORG:ATARU"))
    }

    /// No phone number, ever. ATARU is not on the telephone network, and the
    /// Asterisk extension in a phone field would be a live short code one
    /// habitual tap away.
    func testTheCardCarriesNoDialableNumber() {
        let card = ATARUContact.vCard(handle: "ataru")
        XCTAssertFalse(card.contains("TEL"), "a dialable field must never appear")
        XCTAssertTrue(card.contains("IMPP"), "the handle belongs in the IM slot")
    }

    /// The card and the CallKit path have to agree about what ATARU's address
    /// is, so both read the same constant.
    func testTheHandleIsTheOneTheCallPathUses() {
        XCTAssertTrue(ATARUContact.vCard().contains(CallIntent.handleValue))
    }

    /// A stray semicolon or comma in a value would terminate the field and
    /// produce a card iOS reads as something else entirely.
    func testValuesAreEscaped() {
        let card = ATARUContact.vCard(handle: "a;b,c")
        XCTAssertTrue(card.contains("a\\;b\\,c"))
    }

    func testWritingTheCardProducesAVCFFile() throws {
        let card = try ATARUContact.card()
        XCTAssertEqual(card.fileURL.pathExtension, "vcf",
                       "the extension is how the share sheet decides to offer Add to Contacts")
        let written = try String(contentsOf: card.fileURL, encoding: .utf8)
        XCTAssertEqual(written, ATARUContact.vCard())
    }
}
