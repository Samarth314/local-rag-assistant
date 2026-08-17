import Foundation

/// The list of cards to pick from, and what each one gives you.
///
/// ## Where the data comes from, and where it must not come from
///
/// `GET /api/cards/catalog`, populated by the scraping agent and refreshed
/// roughly annually — issuers change these once or twice a year, not monthly.
///
/// **The app ships almost no benefit data of its own, deliberately.** Amounts
/// and cycles are the kind of fact that is confidently wrong: a hardcoded "$200
/// airline credit, calendar year" that is actually anniversary-year costs the
/// user the credit, and they find out in November. So the bundled fallback is
/// card NAMES only — which are stable, checkable, and harmless — and every
/// amount arrives from the catalog or is typed by the person who holds the
/// card and can read their own statement.
///
/// Anything the catalog supplies carries `source` and `checkedAt` so the
/// screen can say where a number came from and how old it is, rather than
/// presenting a scrape as gospel.
struct CardCatalog: Codable, Hashable {
    var cards: [Entry]
    /// When the agent last refreshed this. Surfaced in the UI: a benefit list
    /// eighteen months stale is worth knowing about before you plan around it.
    var checkedAt: Date?

    struct Entry: Codable, Hashable, Identifiable {
        /// Stable key, so a refreshed catalog updates a held card in place.
        let id: String
        var issuer: String
        var name: String
        var benefits: [Benefit]
        /// Where the agent read this - an issuer page, ideally. Shown to the
        /// user so a wrong number is traceable rather than mysterious.
        var source: String?

        struct Benefit: Codable, Hashable {
            var title: String
            var merchant: String?
            var amount: Decimal?
            var cycle: BenefitCycle
            var notes: String?

            var domain: CardBenefit {
                CardBenefit(title: title, merchant: merchant, amount: amount,
                            cycle: cycle, notes: notes)
            }
        }

        /// A held card built from this entry. New UUIDs throughout: catalog
        /// identity is `id`, and the benefit UUIDs have to be unique per
        /// HOLDER because redemptions are keyed by them.
        func held() -> HeldCard {
            HeldCard(catalogID: id, issuer: issuer, name: name,
                     benefits: benefits.map(\.domain))
        }
    }

    /// Card names only — no amounts, no cycles. See the type's note.
    ///
    /// These exist so the picker is useful before the agent has run: choose
    /// your card, then add its credits yourself or wait for the catalog to
    /// fill them in. A short list of common ones beats a long list of guesses.
    static let bundled = CardCatalog(cards: [
        entry("amex-platinum", "American Express", "Platinum"),
        entry("amex-gold", "American Express", "Gold"),
        entry("amex-green", "American Express", "Green"),
        entry("amex-blue-cash-preferred", "American Express", "Blue Cash Preferred"),
        entry("chase-sapphire-reserve", "Chase", "Sapphire Reserve"),
        entry("chase-sapphire-preferred", "Chase", "Sapphire Preferred"),
        entry("chase-freedom-unlimited", "Chase", "Freedom Unlimited"),
        entry("capital-one-venture-x", "Capital One", "Venture X"),
        entry("capital-one-savor", "Capital One", "Savor"),
        entry("citi-strata-premier", "Citi", "Strata Premier"),
        entry("citi-double-cash", "Citi", "Double Cash"),
        entry("discover-it", "Discover", "it Cash Back"),
        entry("boa-premium-rewards", "Bank of America", "Premium Rewards"),
        entry("wells-fargo-autograph", "Wells Fargo", "Autograph"),
        entry("apple-card", "Apple", "Card")
    ], checkedAt: nil)

    private static func entry(_ id: String, _ issuer: String, _ name: String) -> Entry {
        Entry(id: id, issuer: issuer, name: name, benefits: [], source: nil)
    }

    /// Catalog entries not already held, for the picker.
    func available(excluding held: [HeldCard]) -> [Entry] {
        let taken = Set(held.compactMap(\.catalogID))
        return cards.filter { !taken.contains($0.id) }
            .sorted { ($0.issuer, $0.name) < ($1.issuer, $1.name) }
    }
}
