import Foundation

/// A credit that has to be used before a date or it is gone.
///
/// ## Why the cycle is the whole feature
///
/// "$75 of Lululemon credit each quarter" is worth nothing as a fact and a
/// great deal as a *deadline*. The value here is entirely in knowing which
/// period you are in, when it closes, and whether you have already spent it —
/// so the cycle arithmetic below is the part that has to be right, and it is
/// the only part with real tests.
///
/// The failure that makes this whole thing useless is subtle: mark the credit
/// redeemed in Q3, and if redemption is a plain boolean it stays redeemed in
/// Q4, hiding the money it exists to protect. Redemptions are therefore
/// recorded against a *period*, never against the benefit — see
/// `CardWallet.isRedeemed`.
enum BenefitCycle: String, Codable, CaseIterable, Hashable {
    case monthly, quarterly, semiannual
    /// Resets on 1 January, whoever you are.
    case annualCalendar
    /// Resets on the card's own anniversary. Genuinely different from the
    /// calendar year and routinely confused with it — an anniversary-year
    /// credit assumed to run to 31 December is a credit lost in November.
    case annualCardmember

    var title: String {
        switch self {
        case .monthly:         return "Monthly"
        case .quarterly:       return "Quarterly"
        case .semiannual:      return "Twice a year"
        case .annualCalendar:  return "Yearly (calendar)"
        case .annualCardmember: return "Yearly (card anniversary)"
        }
    }

    /// How many times a year this comes round — for the "you are leaving $X on
    /// the table annually" arithmetic.
    var timesPerYear: Int {
        switch self {
        case .monthly:    return 12
        case .quarterly:  return 4
        case .semiannual: return 2
        case .annualCalendar, .annualCardmember: return 1
        }
    }

    /// The window `date` falls inside: start inclusive, end exclusive.
    ///
    /// `anniversary` is only consulted for `.annualCardmember`, and a missing
    /// one falls back to the calendar year rather than guessing a date — being
    /// wrong about the deadline is the one thing this type must not do.
    func period(containing date: Date, anniversary: Date? = nil,
                calendar: Calendar = .current) -> DateInterval {
        switch self {
        case .monthly:
            return span(of: .month, containing: date, count: 1, calendar: calendar)
        case .quarterly:
            return alignedSpan(monthsPerPeriod: 3, containing: date, calendar: calendar)
        case .semiannual:
            return alignedSpan(monthsPerPeriod: 6, containing: date, calendar: calendar)
        case .annualCalendar:
            return span(of: .year, containing: date, count: 1, calendar: calendar)
        case .annualCardmember:
            guard let anniversary else {
                return BenefitCycle.annualCalendar.period(containing: date, calendar: calendar)
            }
            return anniversaryPeriod(containing: date, anniversary: anniversary,
                                     calendar: calendar)
        }
    }

    private func span(of unit: Calendar.Component, containing date: Date,
                      count: Int, calendar: Calendar) -> DateInterval {
        let start = calendar.dateInterval(of: unit, for: date)?.start ?? date
        let end = calendar.date(byAdding: unit, value: count, to: start) ?? date
        return DateInterval(start: start, end: end)
    }

    /// Quarters and halves, aligned to January rather than to today.
    ///
    /// Q1 is Jan–Mar for everyone; the boundary is a property of the calendar,
    /// not of when the card was opened.
    private func alignedSpan(monthsPerPeriod: Int, containing date: Date,
                             calendar: Calendar) -> DateInterval {
        let month = calendar.component(.month, from: date)      // 1...12
        let index = (month - 1) / monthsPerPeriod               // 0-based period
        var components = calendar.dateComponents([.year], from: date)
        components.month = index * monthsPerPeriod + 1
        components.day = 1
        let start = calendar.date(from: components) ?? date
        let end = calendar.date(byAdding: .month, value: monthsPerPeriod, to: start) ?? date
        return DateInterval(start: start, end: end)
    }

    /// The anniversary year `date` sits in: this year's anniversary if it has
    /// already passed, last year's if it has not.
    private func anniversaryPeriod(containing date: Date, anniversary: Date,
                                   calendar: Calendar) -> DateInterval {
        let opened = calendar.dateComponents([.month, .day], from: anniversary)
        var components = calendar.dateComponents([.year], from: date)
        components.month = opened.month
        components.day = opened.day
        guard var start = calendar.date(from: components) else {
            return BenefitCycle.annualCalendar.period(containing: date, calendar: calendar)
        }
        if start > date {
            start = calendar.date(byAdding: .year, value: -1, to: start) ?? start
        }
        let end = calendar.date(byAdding: .year, value: 1, to: start) ?? date
        return DateInterval(start: start, end: end)
    }
}

/// One credit on one card.
struct CardBenefit: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String
    /// Where it has to be spent. Nil for credits with no single merchant.
    var merchant: String?
    /// In whole currency units. Nil for perks with no cash value — lounge
    /// access, free checked bags — which still belong here because "what does
    /// this card actually give me" is half the question being asked.
    var amount: Decimal?
    var cycle: BenefitCycle
    var notes: String?

    init(id: UUID = UUID(), title: String, merchant: String? = nil,
         amount: Decimal? = nil, cycle: BenefitCycle, notes: String? = nil) {
        self.id = id
        self.title = title
        self.merchant = merchant
        self.amount = amount
        self.cycle = cycle
        self.notes = notes
    }

    var hasCashValue: Bool { (amount ?? 0) > 0 }

    /// Folds a refreshed catalog into the benefits a card already carries.
    ///
    /// ## Why identity has to survive
    ///
    /// Redemptions are keyed by `benefit.id`, so a refresh that hands every
    /// credit a fresh UUID silently un-ticks the lot. The user opens the app
    /// the morning after the annual scrape and every credit they have already
    /// spent is back on the list — which is worse than not refreshing at all,
    /// because now they will go and try to spend it twice. Rows matching by
    /// title keep their id and take the catalog's numbers.
    ///
    /// ## Why this is a union, unlike `NoteTask.merge`
    ///
    /// A parsed note is authoritative about that note, so the merge next door
    /// returns only what came back. A catalog is NOT authoritative about a
    /// card: terms vary by when the card was opened and what retention offer
    /// was taken, so the credits someone typed themselves are exactly the ones
    /// the scraper was never going to know. Anything with no catalog
    /// counterpart is kept, not dropped.
    static func merge(catalog: [CardBenefit], into existing: [CardBenefit]) -> [CardBenefit] {
        var byTitle: [String: CardBenefit] = [:]
        for benefit in existing {
            byTitle[matchKey(benefit.title)] = byTitle[matchKey(benefit.title)] ?? benefit
        }

        var claimed = Set<UUID>()
        let refreshed = catalog.map { entry -> CardBenefit in
            guard let previous = byTitle[matchKey(entry.title)],
                  claimed.insert(previous.id).inserted else { return entry }
            return CardBenefit(id: previous.id, title: entry.title,
                               merchant: entry.merchant, amount: entry.amount,
                               cycle: entry.cycle, notes: entry.notes)
        }
        // Hand-entered credits the catalog has never heard of.
        let kept = existing.filter { !claimed.contains($0.id) }
        return refreshed + kept
    }

    /// Case and trailing punctuation are not the difference between two credits.
    private static func matchKey(_ title: String) -> String {
        title.lowercased().trimmingCharacters(
            in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".,;:!?")))
    }
}

/// A card the user actually holds.
struct HeldCard: Identifiable, Codable, Hashable {
    let id: UUID
    /// Catalog key, so a refreshed catalog can update a held card's benefits
    /// without the user re-picking it.
    var catalogID: String?
    var issuer: String
    var name: String
    /// When the card was opened. Only needed for `.annualCardmember` credits,
    /// and its absence is why those fall back to the calendar year.
    var anniversary: Date?
    var benefits: [CardBenefit]

    init(id: UUID = UUID(), catalogID: String? = nil, issuer: String, name: String,
         anniversary: Date? = nil, benefits: [CardBenefit] = []) {
        self.id = id
        self.catalogID = catalogID
        self.issuer = issuer
        self.name = name
        self.anniversary = anniversary
        self.benefits = benefits
    }

    var displayName: String { "\(issuer) \(name)" }
}

/// One benefit, resolved against a moment in time.
struct BenefitStatus: Identifiable, Hashable {
    let card: HeldCard
    let benefit: CardBenefit
    let period: DateInterval
    let isRedeemed: Bool

    var id: String { "\(benefit.id)|\(period.start.timeIntervalSince1970)" }

    func daysRemaining(from now: Date, calendar: Calendar = .current) -> Int {
        // Counted in whole days to the LAST day the credit is usable, not to
        // the exclusive end instant: a period ending at midnight on 1 October
        // is usable all of 30 September, and reporting that as 0 days left
        // would send the reminder a day late.
        let lastDay = calendar.startOfDay(for: period.end.addingTimeInterval(-1))
        let today = calendar.startOfDay(for: now)
        return calendar.dateComponents([.day], from: today, to: lastDay).day ?? 0
    }

    /// How urgent this is, for sorting. Unredeemed and closing soon first.
    func urgency(from now: Date) -> Int {
        isRedeemed ? Int.max : daysRemaining(from: now)
    }
}
