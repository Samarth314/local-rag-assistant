import Foundation

/// The cards the user holds, and what they have already claimed.
///
/// Lives in Application Support alongside `notes.json`, and for the same
/// reason: this is authored, not fetched. The catalog can be downloaded again;
/// which cards someone carries and what they have already spent cannot.
@MainActor
final class CardWallet: ObservableObject {
    @Published private(set) var cards: [HeldCard] = []
    /// Keys of the form `<benefit uuid>|<period start, seconds>`.
    ///
    /// A SET OF PERIODS, not a flag per benefit. Marking the Lululemon credit
    /// used in Q3 must not carry into Q4 — a boolean there would hide exactly
    /// the money this feature exists to protect, and it would do it silently,
    /// on the first day of a new quarter, months after the code was written.
    @Published private(set) var redemptions: Set<String> = []

    /// What went wrong with the file, if anything. Nil is the normal case.
    ///
    /// The same surface `NoteStore` carries, and for a sharper reason: a
    /// silently failed write here means a credit the user ticked comes back
    /// unticked, so they go and try to spend money that is already gone. A
    /// wallet that cannot save has to say so.
    @Published private(set) var failure: String?

    private let fileURL: URL?
    private let fileManager = FileManager.default
    /// Set when `load` found a file it could not read. The next write moves it
    /// aside rather than overwriting: whatever is in there is the only record
    /// of what has already been claimed.
    private var isUnreadable = false

    init(fileURL: URL? = CardWallet.defaultFileURL()) {
        self.fileURL = fileURL
        load()
    }

    nonisolated static func defaultFileURL() -> URL? {
        let manager = FileManager.default
        guard let directory = manager.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask).first else { return nil }
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "cards.json")
    }

    // MARK: - Cards

    func add(_ card: HeldCard) {
        guard !cards.contains(where: { $0.id == card.id }) else { return }
        cards.append(card)
        save()
    }

    func remove(_ card: HeldCard) {
        cards.removeAll { $0.id == card.id }
        // Redemption records for a card that is gone are dead weight, and one
        // re-added later should not inherit ticks from before.
        let ids = Set(card.benefits.map { $0.id.uuidString })
        redemptions = redemptions.filter { key in
            !ids.contains(String(key.split(separator: "|").first ?? ""))
        }
        save()
    }

    func setAnniversary(_ date: Date?, for card: HeldCard) {
        guard let index = cards.firstIndex(where: { $0.id == card.id }) else { return }
        cards[index].anniversary = date
        save()
    }

    func addBenefit(_ benefit: CardBenefit, to card: HeldCard) {
        guard let index = cards.firstIndex(where: { $0.id == card.id }) else { return }
        cards[index].benefits.append(benefit)
        save()
    }

    func removeBenefit(_ benefit: CardBenefit, from card: HeldCard) {
        guard let index = cards.firstIndex(where: { $0.id == card.id }) else { return }
        cards[index].benefits.removeAll { $0.id == benefit.id }
        save()
    }

    /// Takes on a refreshed catalog for every card that came from one.
    ///
    /// `catalogID` has always claimed a refresh could update a held card
    /// "without the user re-picking it", and until now nothing did it. Doing
    /// it naively is worse than not doing it: benefit ids are what redemptions
    /// are keyed by, so fresh ones would un-tick every credit already spent
    /// this period — see `CardBenefit.merge`, which keeps identity and keeps
    /// hand-entered credits the scraper does not know about.
    func refresh(from catalog: CardCatalog) {
        var changed = false
        for (index, card) in cards.enumerated() {
            guard let catalogID = card.catalogID,
                  let entry = catalog.cards.first(where: { $0.id == catalogID }),
                  !entry.benefits.isEmpty else { continue }
            let merged = CardBenefit.merge(catalog: entry.benefits.map(\.domain),
                                           into: card.benefits)
            guard merged != card.benefits else { continue }
            cards[index].benefits = merged
            changed = true
        }
        if changed { save() }
    }

    // MARK: - Redemption

    /// Pure derivation, so it is not actor-isolated: the key is a fact about a
    /// benefit and a period, not about the wallet holding them, and tests of
    /// the period arithmetic should not need the main actor to ask for one.
    nonisolated static func key(_ benefit: CardBenefit, period: DateInterval) -> String {
        "\(benefit.id.uuidString)|\(Int(period.start.timeIntervalSince1970))"
    }

    func isRedeemed(_ benefit: CardBenefit, period: DateInterval) -> Bool {
        redemptions.contains(Self.key(benefit, period: period))
    }

    func setRedeemed(_ redeemed: Bool, benefit: CardBenefit, period: DateInterval) {
        let key = Self.key(benefit, period: period)
        if redeemed { redemptions.insert(key) } else { redemptions.remove(key) }
        save()
    }

    // MARK: - Reading

    /// Every benefit the user holds, resolved against `now` and ordered by how
    /// soon it disappears.
    func statuses(at now: Date = Date(), calendar: Calendar = .current) -> [BenefitStatus] {
        cards.flatMap { card in
            card.benefits.map { benefit in
                let period = benefit.cycle.period(containing: now,
                                                  anniversary: card.anniversary,
                                                  calendar: calendar)
                return BenefitStatus(card: card, benefit: benefit, period: period,
                                     isRedeemed: isRedeemed(benefit, period: period))
            }
        }
        .sorted {
            let left = $0.urgency(from: now), right = $1.urgency(from: now)
            return left == right ? $0.benefit.title < $1.benefit.title : left < right
        }
    }

    /// What is still on the table this period, in cash.
    func unclaimedValue(at now: Date = Date(), calendar: Calendar = .current) -> Decimal {
        statuses(at: now, calendar: calendar)
            .filter { !$0.isRedeemed }
            .compactMap(\.benefit.amount)
            .reduce(0, +)
    }

    // MARK: - Storage

    private struct Stored: Codable {
        var cards: [HeldCard]
        var redemptions: [String]
    }

    private func load() {
        guard let fileURL else {
            failure = "There is nowhere on this phone to keep your cards."
            return
        }
        // No file is the first launch, and the empty state is the truth.
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        guard let data = try? Data(contentsOf: fileURL) else {
            isUnreadable = true
            failure = "Couldn't open your saved cards. Nothing has been changed."
            return
        }
        guard let stored = try? JSONDecoder().decode(Stored.self, from: data) else {
            isUnreadable = true
            failure = "Your saved cards couldn't be read. The file is still on the phone and nothing has been overwritten."
            return
        }
        cards = stored.cards
        redemptions = Set(stored.redemptions)
    }

    private func save() {
        guard let fileURL else {
            failure = "There is nowhere on this phone to keep your cards."
            return
        }
        // A file that would not decode is moved aside, never written over: it
        // is the only record of what has already been claimed.
        if isUnreadable {
            let stamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            let aside = fileURL.deletingLastPathComponent()
                .appending(path: "cards-unreadable-\(stamp).json")
            guard (try? fileManager.moveItem(at: fileURL, to: aside)) != nil else {
                failure = "Couldn't save - the existing card file is unreadable and could not be moved aside."
                return
            }
            isUnreadable = false
        }
        guard let data = try? JSONEncoder().encode(
            Stored(cards: cards, redemptions: Array(redemptions)))
        else {
            failure = "Couldn't save your cards."
            return
        }
        do {
            try data.write(to: fileURL, options: .atomic)
            failure = nil
        } catch {
            failure = "Couldn't save to the phone. What you see is correct until you close the app."
        }
    }
}
