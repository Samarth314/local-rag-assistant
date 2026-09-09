import Foundation

// The monthly statement checklist: what the finance service says is collected,
// what is missing, and where to go and get it.
//
// Everything in this file is pure - decoding, ordering, the nudge rule and the
// login allowlist - so the page above it is only layout. That split is
// deliberate: the login URLs in particular are a security claim, and a claim
// that lives in a view cannot be tested.

// MARK: - The contract

/// `GET <root>/api/statements`, decoded tolerantly.
///
/// EVERY KEY IS OPTIONAL, including ones the service always sends today. These
/// screens have documented degraded variants where most of a payload vanishes,
/// and a decoder that refuses the whole document over one absent key turns a
/// partial answer into no answer at all. The page reads through accessors that
/// state what an absent value means instead.
struct StatementsDTO: Codable, Equatable {

    /// What the service could tell about one account.
    ///
    /// `status` is the whole point of the row, and an unrecognised one is
    /// `.unknown` rather than a decode failure: the service may learn a fourth
    /// state before this app does, and the honest rendering of that is "the
    /// server said something this build does not know", not a blank screen.
    enum Status: String, Codable, Equatable {
        case present
        case missing
        case not_posted_yet
        case unknown

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let raw = try? container.decode(String.self)
            self = raw.flatMap(Status.init(rawValue:)) ?? .unknown
        }

        /// Sorted missing -> not_posted_yet -> present -> unknown: the order a
        /// person works the list in. What needs doing first is at the top, and
        /// what the app cannot describe is at the bottom rather than hidden.
        var rank: Int {
            switch self {
            case .missing:         return 0
            case .not_posted_yet:  return 1
            case .present:         return 2
            case .unknown:         return 3
            }
        }

        /// Never colour alone. The symbol and the word carry the state; the
        /// tint is the third copy of it.
        var symbol: String {
            switch self {
            case .present:         return "checkmark.circle.fill"
            case .missing:         return "exclamationmark.circle.fill"
            case .not_posted_yet:  return "clock"
            case .unknown:         return "questionmark.circle"
            }
        }

        var word: String {
            switch self {
            case .present:         return "Filed"
            case .missing:         return "Missing"
            case .not_posted_yet:  return "Not posted yet"
            case .unknown:         return "Unknown"
            }
        }
    }

    struct Sitting: Codable, Equatable {
        let month: String?
        let label: String?
        let date: String?
        let is_today_or_past: Bool?
        /// The sitting date minus the longest lead time of any source that
        /// needs asking in advance. Absent on a contract that predates leads.
        let request_by: String?
    }

    struct Source: Codable, Equatable {
        let id: String?
        let label: String?
        let login_url: String?
        let close_day: Int?
        let posts_by_day: Int?
        let target_month: String?
        let status: Status?
        let latest_period_end: String?
        let gaps: [String]?
        /// How many days before the sitting this source has to be ASKED for.
        /// Zero or absent for a source that hands its file over on the spot.
        let request_lead_days: Int?
        /// What asking actually involves, in the service's own words. Guidance
        /// for a row that still needs collecting, never an error.
        let request_note: String?

        /// An absent status is not "fine". See `Status`.
        var state: Status { status ?? .unknown }

        /// What a row is called when the service did not name it.
        var displayLabel: String { label ?? id ?? "Unnamed account" }

        /// The note, when there is one worth drawing.
        ///
        /// A filed row is done, and telling somebody how to ask for a file they
        /// already have is noise. Whitespace-only text is treated as absent -
        /// a blank secondary line under a row reads as a rendering fault.
        var visibleRequestNote: String? {
            guard state != .present,
                  let note = request_note?.trimmingCharacters(
                    in: .whitespacesAndNewlines),
                  !note.isEmpty
            else { return nil }
            return note
        }
    }

    struct Store: Codable, Equatable {
        let path: String?
        let ok: Bool?
        let reason: String?
    }

    let as_of: String?
    let sitting_day: Int?
    let sitting: Sitting?
    let sources: [Source]?
    let missing: [String]?
    let not_posted_yet: [String]?
    let complete: Bool?
    let n_missing: Int?
    let store: Store?
    /// The ids that have to be asked for ahead of the sitting and are not in
    /// yet. Computed by the service, because only it knows what has arrived.
    let request_ahead: [String]?

    // MARK: - What the page asks it

    /// The rows, in working order. Ties broken by label and then by id so the
    /// list is stable between refreshes - a checklist that reshuffles under a
    /// thumb is a checklist nobody finishes.
    var orderedSources: [Source] {
        (sources ?? []).enumerated().sorted { lhs, rhs in
            let l = lhs.element, r = rhs.element
            if l.state.rank != r.state.rank { return l.state.rank < r.state.rank }
            let ll = l.displayLabel.lowercased(), rl = r.displayLabel.lowercased()
            if ll != rl { return ll < rl }
            let li = l.id ?? "", ri = r.id ?? ""
            if li != ri { return li < ri }
            // Two rows the service sent as duplicates keep the order it sent
            // them in, rather than swapping places at random.
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    var missingCount: Int { n_missing ?? missing?.count ?? 0 }

    /// Whether the checklist should nag.
    ///
    /// Both halves matter. Something missing on the 3rd is not yet a problem -
    /// the statements have not all been cut. On the sitting day it is the
    /// whole job, so that is the only day this shouts.
    var showsNudge: Bool {
        missingCount > 0 && (sitting?.is_today_or_past ?? false)
    }

    /// The one line under the header.
    var stateLine: String {
        if missingCount > 0 {
            return "\(missingCount) missing"
        }
        if !(not_posted_yet ?? []).isEmpty {
            let day = sitting_day ?? 10
            return "Not all posted yet - the \(ordinal(day)) is the day"
        }
        return "Complete"
    }

    /// The header's "ask for this early" line, or nil for no line at all.
    ///
    /// Robinhood does not hand its activity report over on the spot - it is
    /// requested and arrives about a day later - so a sitting that is meant to
    /// be ONE sitting has to ask a couple of days ahead. The line is guidance
    /// with a deadline, so it disappears once the deadline passes: after
    /// `request_by` the advice is no longer actionable, and repeating it would
    /// only be a reproach.
    ///
    /// `today` is passed in rather than read here, which is what makes the rule
    /// testable. Both dates are ISO `yyyy-MM-dd`, where lexicographic order IS
    /// chronological order - but only for well-formed values, so a malformed
    /// `request_by` hides the line rather than comparing garbage.
    func requestLine(today: String) -> String? {
        guard let by = sitting?.request_by,
              Self.isISODate(by), Self.isISODate(today),
              today <= by
        else { return nil }
        let ids = request_ahead ?? []
        guard !ids.isEmpty else { return nil }
        let names = ids.map { id in
            sources?.first { $0.id == id }?.displayLabel ?? id
        }
        return "Request \(Self.list(names)) by \(by)"
    }

    /// Today, as the device's own calendar spells it.
    static func todayISO(_ date: Date = Date(),
                         calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        guard let y = parts.year, let m = parts.month, let d = parts.day
        else { return "" }
        return String(format: "%04d-%02d-%02d", y, m, d)
    }

    /// Exactly `yyyy-MM-dd`. Anything else is not a date this can order.
    private static func isISODate(_ value: String) -> Bool {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 4, parts[1].count == 2, parts[2].count == 2
        else { return false }
        return parts.allSatisfy { $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }
    }

    /// "Robinhood", "Robinhood and Amex", "A, B and C".
    private static func list(_ names: [String]) -> String {
        switch names.count {
        case 0:  return ""
        case 1:  return names[0]
        case 2:  return "\(names[0]) and \(names[1])"
        default: return names.dropLast().joined(separator: ", ")
                 + " and \(names[names.count - 1])"
        }
    }

    /// True when the store itself could not be read, which makes every row
    /// below it a guess. The page shows the reason and the login buttons and
    /// nothing else.
    var storeIsBroken: Bool { store != nil && store?.ok == false }

    /// "2026-09" to "September", for the nudge line. Nil rather than a guess
    /// when the month is absent or malformed.
    var sittingMonthName: String? {
        guard let month = sitting?.month else { return nil }
        let parts = month.split(separator: "-")
        guard parts.count >= 2, let index = Int(parts[1]), (1...12).contains(index)
        else { return nil }
        return DateFormatter().monthSymbols[index - 1]
    }

    private func ordinal(_ n: Int) -> String {
        let suffix: String
        switch (n % 100, n % 10) {
        case (11, _), (12, _), (13, _): suffix = "th"
        case (_, 1): suffix = "st"
        case (_, 2): suffix = "nd"
        case (_, 3): suffix = "rd"
        default: suffix = "th"
        }
        return "\(n)\(suffix)"
    }
}

/// `POST <root>/api/statements/upload`, decoded the same way.
struct StatementsUploadDTO: Codable, Equatable {
    struct Accepted: Codable, Equatable {
        let name: String?
        let bytes: Int?
    }
    struct Rejected: Codable, Equatable {
        let name: String?
        let reason: String?
    }
    let accepted: [Accepted]?
    let rejected: [Rejected]?
    let inbox: String?
}

// MARK: - Where "Log in" goes

/// The only hosts this page will ever open.
///
/// THE SERVER DOES NOT GET TO CHOOSE THE HOST. `login_url` arrives in the
/// payload, and the host it names is matched against this table before
/// anything opens. A bank login is exactly the link worth spoofing, and "the
/// finance service is trusted" is a statement about today's finance service
/// rather than a property of the app.
///
/// What the payload DOES get to choose, once the host clears, is the rest of
/// the link. Arya pins the deep links in the vault - the statements page of a
/// broker, the download-transactions page of a bank - and the vault is the
/// single source of truth for them, so an allowlisted `https` link opens
/// exactly as sent, path and query included. The allowlist is what makes that
/// safe: the worst a wrong deep link can do is land on the wrong page of a
/// bank the app already trusts, never on a phishing host.
///
/// The entries below are canonical ROOTS and stay that way. They are the
/// fallback for a row the payload could not place, and the full list rendered
/// when the store is broken - never a place to paste an account-specific URL.
enum StatementLogin {

    struct Known: Identifiable, Equatable {
        let id: String
        let label: String
        let url: URL
    }

    /// The six sources the finance service tracks, and nothing else.
    static let catalog: [Known] = [
        Known(id: "wellsfargo-checking", label: "Wells Fargo checking",
              url: URL(string: "https://www.wellsfargo.com/")!),
        Known(id: "amex-card-monthly", label: "Amex card",
              url: URL(string: "https://www.americanexpress.com/")!),
        Known(id: "amex-savings-csv", label: "Amex savings",
              url: URL(string: "https://www.americanexpress.com/")!),
        Known(id: "capitalone-monthly", label: "Capital One",
              url: URL(string: "https://www.capitalone.com/")!),
        Known(id: "fidelity-statement", label: "Fidelity",
              url: URL(string: "https://www.fidelity.com/")!),
        Known(id: "robinhood-csv", label: "Robinhood",
              url: URL(string: "https://robinhood.com/")!),
    ]

    /// Every host any button on this page may reach. Derived from the catalog,
    /// so the two can never disagree.
    static var allowedHosts: Set<String> {
        Set(catalog.compactMap { $0.url.host?.lowercased() })
    }

    /// Where a row's "Log in" button goes, or nil for no button at all.
    ///
    /// Three outcomes, in this order:
    ///
    /// 1. The advertised `login_url` opens EXACTLY AS SENT - path, query and
    ///    fragment intact - if and only if it is `https`, its host is on
    ///    `allowedHosts`, and its authority carries no userinfo and no explicit
    ///    port. That is the pinned-deep-link case, and the vault is the source
    ///    of truth for it.
    /// 2. Otherwise a known source id opens its canonical root from the
    ///    catalog, and an id this build has never heard of opens the canonical
    ///    root of its advertised host if that host is allowlisted.
    /// 3. Otherwise no button. A row without a login link is a much smaller
    ///    failure than a link to somewhere unexpected.
    ///
    /// The userinfo and port checks are not decoration. `https://a.example@`
    /// prefixed to an attacker's host puts an allowlisted-looking name in the
    /// URL a person reads while the request goes elsewhere, and a port turns a
    /// trusted hostname into a pointer at whatever answers on it.
    static func url(forID id: String?, advertised: String?) -> URL? {
        if let advertised, let asSent = advertisedIfAllowed(advertised) {
            return asSent
        }
        if let id, let known = catalog.first(where: { $0.id == id }) {
            return known.url
        }
        guard let advertised, let host = normalizedHost(of: advertised)
        else { return nil }
        return catalog.first { $0.url.host?.lowercased() == host }?.url
    }

    /// The advertised URL itself, when every condition in rule 1 holds.
    ///
    /// Deliberately one guard: a link that fails any single clause is not
    /// repaired, because repairing it would mean opening something the payload
    /// did not actually say.
    private static func advertisedIfAllowed(_ advertised: String) -> URL? {
        guard let components = URLComponents(string: advertised),
              components.scheme?.lowercased() == "https",
              components.user == nil,
              components.password == nil,
              components.port == nil,
              let host = normalizedHost(of: advertised),
              allowedHosts.contains(host),
              let url = URL(string: advertised)
        else { return nil }
        return url
    }

    /// The host as the allowlist spells it: lowercased, and with the trailing
    /// dot of a fully-qualified name removed. "robinhood.com." and
    /// "robinhood.com" are the same host to DNS, so they are the same host
    /// here - matching on the raw string would let a trailing dot walk past
    /// the allowlist.
    private static func normalizedHost(of urlString: String) -> String? {
        guard let host = URLComponents(string: urlString)?.host?.lowercased(),
              !host.isEmpty
        else { return nil }
        return host.hasSuffix(".") ? String(host.dropLast()) : host
    }

    static func url(for source: StatementsDTO.Source) -> URL? {
        url(forID: source.id, advertised: source.login_url)
    }
}

// MARK: - Uploading

/// A multipart/form-data body, built by hand.
///
/// Pure and separately testable on purpose. This is the one place in the app
/// that hand-assembles a request body, and the failure it can have - a missing
/// CRLF, a boundary that does not close - produces a 400 from the server with
/// nothing on the phone to say why.
enum MultipartBody {

    struct Part: Equatable {
        let filename: String
        let contentType: String
        let data: Data
    }

    /// What the server is told a picked file is.
    ///
    /// From the extension, and from a closed set: the file importer is limited
    /// to PDF and CSV, so anything else here means the picker was bypassed and
    /// the honest label is the generic one rather than a guess.
    static func contentType(forFilename name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "pdf": return "application/pdf"
        case "csv": return "text/csv"
        default:    return "application/octet-stream"
        }
    }

    static func boundary() -> String { "ataru-\(UUID().uuidString)" }

    static func encode(parts: [Part], boundary: String, field: String = "files") -> Data {
        var body = Data()
        for part in parts {
            append(&body, "--\(boundary)\r\n")
            append(&body, "Content-Disposition: form-data; name=\"\(field)\"; "
                   + "filename=\"\(escape(part.filename))\"\r\n")
            append(&body, "Content-Type: \(part.contentType)\r\n\r\n")
            body.append(part.data)
            append(&body, "\r\n")
        }
        append(&body, "--\(boundary)--\r\n")
        return body
    }

    /// A quote or a newline in a filename would otherwise end the header early.
    /// Files come from the Files app, so the name is whatever a person typed.
    private static func escape(_ name: String) -> String {
        name.replacingOccurrences(of: "\\", with: "")
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }

    private static func append(_ data: inout Data, _ string: String) {
        data.append(Data(string.utf8))
    }
}
