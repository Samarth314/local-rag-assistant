import Foundation

/// The ATARU entry for the user's address book, as a file iOS can import.
///
/// The contact is what gives the calling intent somewhere to live: iOS lists a
/// third-party calling app *underneath a contact*, so with no contact there is
/// nothing to list it under.
///
/// ## Why this no longer touches Contacts at all
///
/// "It prompts for full address book access. I don't know why it needs that
/// just to add the contact card." He is right, and it did not need it. The old
/// implementation used `CNContactStore`: it requested access, searched the
/// whole address book for an existing ATARU card, and saved through a
/// `CNSaveRequest`. Two of those three steps are the app reading his contacts.
///
/// The search was for duplicate detection - "this is a button someone may well
/// press twice". That was never worth what it cost. Reading every contact on
/// the phone to save the user from a second identical card is a bad trade, and
/// adding one twice is the user's business anyway.
///
/// What replaces it is a vCard written to a temporary file and handed to the
/// system. iOS shows its own sheet, "Add to Contacts" is one of the options in
/// it, and the OS - not this app - writes the entry. **Nothing in this file
/// imports Contacts or constructs a `CNContactStore`**, which is the whole
/// argument for why no permission prompt can appear: the prompt is triggered by
/// touching the store, and there is no store here to touch.
///
/// Deliberately no phone number, unchanged from the original. ATARU is not
/// reachable on the telephone network, and putting the Asterisk extension
/// (`100`) in a phone field would create an entry that dials a live short code
/// the moment somebody taps it out of habit. The handle goes in the
/// instant-message slot instead, which is the conventional home for an
/// app-specific address and is not dialable.
enum ATARUContact {

    enum Failure: LocalizedError, Equatable {
        case couldNotWrite(String)

        var errorDescription: String? {
            switch self {
            case .couldNotWrite(let detail):
                return "Couldn't build the contact card: \(detail)"
            }
        }
    }

    static let organizationName = "ATARU"
    static let serviceName = "ATARU"
    static let note = "Your private assistant. Answers from documents indexed on your own server."

    /// A vCard on disk, ready to hand to the system.
    ///
    /// `Identifiable` so a SwiftUI sheet can be driven by it directly.
    struct Card: Identifiable {
        let fileURL: URL
        var id: String { fileURL.path }
    }

    /// The vCard text. Pure, and therefore testable without a device.
    ///
    /// vCard 3.0 rather than 4.0: it is what iOS imports most predictably, and
    /// what every other app on the phone exports. `IMPP` carries the handle the
    /// CallKit path uses, so the card and the call agree about what ATARU's
    /// address is - they read it from the same constant.
    static func vCard(handle: String = CallIntent.handleValue) -> String {
        // Escaped per RFC 6350: commas, semicolons and backslashes in a value
        // would otherwise terminate the field.
        func escape(_ value: String) -> String {
            value
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: ";", with: "\\;")
                .replacingOccurrences(of: ",", with: "\\,")
                .replacingOccurrences(of: "\n", with: "\\n")
        }
        return [
            "BEGIN:VCARD",
            "VERSION:3.0",
            "N:;\(escape(organizationName));;;",
            "FN:\(escape(organizationName))",
            "ORG:\(escape(organizationName));",
            "IMPP;X-SERVICE-TYPE=\(escape(serviceName)):\(escape(serviceName).lowercased()):\(escape(handle))",
            "X-SOCIALPROFILE;TYPE=\(escape(serviceName)):\(escape(handle))",
            "NOTE:\(escape(note))",
            "END:VCARD",
        ].joined(separator: "\r\n") + "\r\n"
    }

    /// Writes the card to a temporary file for the share sheet.
    ///
    /// A real file with a `.vcf` extension, not a data blob: the extension is
    /// how the system decides to offer "Add to Contacts" at all. It lands in
    /// the temporary directory, which iOS empties on its own.
    static func card() throws -> Card {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "ATARU.vcf")
        do {
            try vCard().data(using: .utf8)?.write(to: url, options: .atomic)
        } catch {
            throw Failure.couldNotWrite(error.localizedDescription)
        }
        return Card(fileURL: url)
    }
}
