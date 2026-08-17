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

    private let fileURL: URL?

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
        guard let fileURL, let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder().decode(Stored.self, from: data)
        else { return }
        cards = stored.cards
        redemptions = Set(stored.redemptions)
    }

    private func save() {
        guard let fileURL,
              let data = try? JSONEncoder().encode(
                Stored(cards: cards, redemptions: Array(redemptions)))
        else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
