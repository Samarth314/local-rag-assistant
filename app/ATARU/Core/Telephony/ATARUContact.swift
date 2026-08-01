import Contacts
import Foundation

/// Creates the ATARU entry in the user's address book.
///
/// The contact is what gives the calling intent somewhere to live: iOS lists a
/// third-party calling app *underneath a contact*, so with no contact there is
/// nothing to list it under.
///
/// Deliberately no phone number. ATARU is not reachable on the telephone
/// network, and putting the Asterisk extension (`100`) in a phone field would
/// create an entry that dials a live short code the moment somebody taps it
/// out of habit. The handle goes in the instant-message slot instead, which is
/// the conventional home for an app-specific address and is not dialable.
enum ATARUContact {

    enum Failure: LocalizedError, Equatable {
        case accessDenied
        case alreadyExists
        case store(String)

        var errorDescription: String? {
            switch self {
            case .accessDenied:
                return "ATARU needs permission to add a contact. Enable Contacts for ATARU in Settings."
            case .alreadyExists:
                return "ATARU is already in your contacts."
            case .store(let detail):
                return detail
            }
        }
    }

    static let organizationName = "ATARU"
    static let serviceName = "ATARU"

    /// Adds the contact, or throws if it is already there.
    ///
    /// Duplicate-checking matters more than it looks: this is triggered from a
    /// button a user may well press twice, and the Contacts framework will
    /// happily create a second identical card without complaint.
    static func add(to store: CNContactStore = CNContactStore()) async throws {
        guard try await requestAccess(store) else { throw Failure.accessDenied }
        guard try !exists(in: store) else { throw Failure.alreadyExists }

        let contact = CNMutableContact()
        contact.givenName = "ATARU"
        contact.organizationName = organizationName
        contact.note = "Your private assistant. Answers from documents indexed on your own server."
        contact.instantMessageAddresses = [
            CNLabeledValue(
                label: CNLabelOther,
                value: CNInstantMessageAddress(username: CallIntent.handleValue,
                                               service: serviceName)
            )
        ]

        let request = CNSaveRequest()
        request.add(contact, toContainerWithIdentifier: nil)
        do {
            try store.execute(request)
        } catch {
            throw Failure.store(error.localizedDescription)
        }
    }

    static func exists(in store: CNContactStore = CNContactStore()) throws -> Bool {
        let predicate = CNContact.predicateForContacts(matchingName: "ATARU")
        let matches = try store.unifiedContacts(
            matching: predicate,
            keysToFetch: [CNContactOrganizationNameKey as CNKeyDescriptor]
        )
        return matches.contains { $0.organizationName == organizationName }
    }

    private static func requestAccess(_ store: CNContactStore) async throws -> Bool {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized: return true
        case .denied, .restricted: return false
        default:
            return try await store.requestAccess(for: .contacts)
        }
    }
}
