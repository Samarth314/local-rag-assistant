import XCTest
@testable import ATARU

/// The cycle arithmetic, which is the whole of this feature's correctness.
///
/// Everything else on the Cards screen is a list. This is the part that
/// decides whether someone is told about $75 on 28 September or told nothing
/// until 2 October, and the failure is silent in both directions — a wrong
/// deadline looks exactly like a right one until the money is gone.
final class CardBenefitTests: XCTestCase {

    /// UTC throughout: a test that quietly depends on the machine's timezone
    /// passes in one office and fails in another, and this arithmetic is
    /// entirely about day boundaries.
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func date(_ string: String) -> Date {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: string) ?? formatter.date(from: string + " 00:00")!
    }

    private func day(_ string: String) -> Date { date(string + " 12:00") }

    // MARK: - Quarters

    func testQuartersAreAlignedToJanuaryNotToToday() {
        // The boundary is a property of the calendar, not of when the card was
        // opened - every quarterly credit resets on the same four dates.
        let cases = [
            ("2026-02-14", "2026-01-01", "2026-04-01"),
            ("2026-04-01", "2026-04-01", "2026-07-01"),
            ("2026-08-16", "2026-07-01", "2026-10-01"),
            ("2026-12-31", "2026-10-01", "2027-01-01")
        ]
        for (now, start, end) in cases {
            let period = BenefitCycle.quarterly.period(containing: day(now),
                                                       calendar: calendar)
            XCTAssertEqual(period.start, day(start).startOfUTCDay(calendar),
                           "wrong quarter start for \(now)")
            XCTAssertEqual(period.end, day(end).startOfUTCDay(calendar),
                           "wrong quarter end for \(now)")
        }
    }

    /// The bug the whole design exists to prevent.
    func testARedemptionDoesNotSurviveIntoTheNextQuarter() {
        let benefit = CardBenefit(title: "Lululemon", amount: 75, cycle: .quarterly)
        let q3 = BenefitCycle.quarterly.period(containing: day("2026-08-16"),
                                               calendar: calendar)
        let q4 = BenefitCycle.quarterly.period(containing: day("2026-10-05"),
                                               calendar: calendar)

        XCTAssertNotEqual(CardWallet.key(benefit, period: q3),
                          CardWallet.key(benefit, period: q4),
                          "one key for two quarters is how Q4's credit goes missing")
    }

    // MARK: - The other cycles

    func testMonthlyRunsToTheFirstOfTheNextMonth() {
        let period = BenefitCycle.monthly.period(containing: day("2026-08-16"),
                                                 calendar: calendar)
        XCTAssertEqual(period.start, day("2026-08-01").startOfUTCDay(calendar))
        XCTAssertEqual(period.end, day("2026-09-01").startOfUTCDay(calendar))
    }

    func testSemiannualSplitsAtJanuaryAndJuly() {
        let first = BenefitCycle.semiannual.period(containing: day("2026-03-02"),
                                                   calendar: calendar)
        let second = BenefitCycle.semiannual.period(containing: day("2026-09-30"),
                                                    calendar: calendar)
        XCTAssertEqual(first.start, day("2026-01-01").startOfUTCDay(calendar))
        XCTAssertEqual(first.end, day("2026-07-01").startOfUTCDay(calendar))
        XCTAssertEqual(second.start, day("2026-07-01").startOfUTCDay(calendar))
        XCTAssertEqual(second.end, day("2027-01-01").startOfUTCDay(calendar))
    }

    func testCalendarYearIsJanuaryToJanuary() {
        let period = BenefitCycle.annualCalendar.period(containing: day("2026-08-16"),
                                                        calendar: calendar)
        XCTAssertEqual(period.start, day("2026-01-01").startOfUTCDay(calendar))
        XCTAssertEqual(period.end, day("2027-01-01").startOfUTCDay(calendar))
    }

    /// The distinction that costs real money when it is got wrong.
    func testAnAnniversaryYearIsNotTheCalendarYear() {
        let opened = day("2023-03-19")

        // In August, the anniversary year started in MARCH and runs to next
        // March - not 1 January to 31 December.
        let period = BenefitCycle.annualCardmember.period(
            containing: day("2026-08-16"), anniversary: opened, calendar: calendar)
        XCTAssertEqual(period.start, day("2026-03-19").startOfUTCDay(calendar))
        XCTAssertEqual(period.end, day("2027-03-19").startOfUTCDay(calendar))
    }

    func testBeforeTheAnniversaryTheYearStartedLastYear() {
        let opened = day("2023-03-19")
        let period = BenefitCycle.annualCardmember.period(
            containing: day("2026-02-01"), anniversary: opened, calendar: calendar)
        XCTAssertEqual(period.start, day("2025-03-19").startOfUTCDay(calendar))
        XCTAssertEqual(period.end, day("2026-03-19").startOfUTCDay(calendar))
    }

    /// Guessing an anniversary would be worse than not having one.
    func testAMissingAnniversaryFallsBackToTheCalendarYear() {
        let period = BenefitCycle.annualCardmember.period(
            containing: day("2026-08-16"), anniversary: nil, calendar: calendar)
        XCTAssertEqual(period, BenefitCycle.annualCalendar.period(
            containing: day("2026-08-16"), calendar: calendar))
    }

    // MARK: - Counting down

    /// Off-by-one here sends every reminder a day late.
    func testTheLastDayOfAPeriodReadsAsZeroDaysNotMinusOne() {
        let status = makeStatus(cycle: .quarterly, now: day("2026-09-30"))
        XCTAssertEqual(status.daysRemaining(from: day("2026-09-30"), calendar: calendar), 0)
    }

    func testTheDayBeforeTheEndReadsAsOne() {
        let status = makeStatus(cycle: .quarterly, now: day("2026-09-29"))
        XCTAssertEqual(status.daysRemaining(from: day("2026-09-29"), calendar: calendar), 1)
    }

    func testTheFirstDayOfAQuarterHasTheWholeQuarterLeft() {
        let status = makeStatus(cycle: .quarterly, now: day("2026-07-01"))
        // July has 31, August 31, September 30 - 92 days, so 91 after today.
        XCTAssertEqual(status.daysRemaining(from: day("2026-07-01"), calendar: calendar), 91)
    }

    // MARK: - Ordering

    func testUnredeemedCreditsSortAheadOfRedeemedOnes() {
        let soon = makeStatus(cycle: .quarterly, now: day("2026-09-29"))
        let redeemed = makeStatus(cycle: .monthly, now: day("2026-09-29"),
                                  isRedeemed: true)
        XCTAssertLessThan(soon.urgency(from: day("2026-09-29")),
                          redeemed.urgency(from: day("2026-09-29")),
                          "a spent credit must never outrank one still on the table")
    }

    // MARK: - Catalog

    func testTheBundledCatalogShipsNamesAndNoInventedAmounts() {
        // Deliberate: a hardcoded amount that is wrong costs the user the
        // credit, and they find out in November. Names are checkable and
        // harmless; numbers come from the agent or from the statement.
        XCTAssertFalse(CardCatalog.bundled.cards.isEmpty)
        for entry in CardCatalog.bundled.cards {
            XCTAssertTrue(entry.benefits.isEmpty,
                          "\(entry.id) ships a benefit the app cannot vouch for")
        }
    }

    func testCardsAlreadyHeldAreNotOfferedAgain() {
        let entry = CardCatalog.bundled.cards[0]
        let available = CardCatalog.bundled.available(excluding: [entry.held()])
        XCTAssertFalse(available.contains { $0.id == entry.id })
    }

    /// Two holders of the same card must not share redemption keys.
    func testEachHeldCardGetsItsOwnBenefitIdentity() {
        var entry = CardCatalog.bundled.cards[0]
        entry.benefits = [.init(title: "Credit", merchant: nil, amount: 50,
                                cycle: .quarterly, notes: nil)]
        let first = entry.held(), second = entry.held()
        XCTAssertNotEqual(first.benefits[0].id, second.benefits[0].id)
    }

    // MARK: - Catalog refresh

    /// The bug an annual scrape would otherwise ship: every credit already
    /// spent this period comes back unticked, and the user goes and tries to
    /// spend money that is gone.
    func testARefreshKeepsBenefitIdentitySoRedemptionsSurvive() {
        let existing = CardBenefit(title: "Lululemon credit", amount: 75, cycle: .quarterly)
        let fromCatalog = CardBenefit(title: "Lululemon credit", amount: 100,
                                      cycle: .quarterly)

        let merged = CardBenefit.merge(catalog: [fromCatalog], into: [existing])

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].id, existing.id, "a refresh renamed the benefit's identity")
        XCTAssertEqual(merged[0].amount, 100, "the refreshed amount was not taken")
    }

    func testARefreshedBenefitKeepsItsRedemptionKey() {
        let existing = CardBenefit(title: "Airline fee credit", amount: 200,
                                   cycle: .annualCalendar)
        let period = BenefitCycle.annualCalendar.period(containing: day("2026-08-16"),
                                                        calendar: calendar)
        let before = CardWallet.key(existing, period: period)

        let merged = CardBenefit.merge(
            catalog: [CardBenefit(title: "Airline fee credit", amount: 200,
                                  cycle: .annualCalendar)],
            into: [existing])

        XCTAssertEqual(CardWallet.key(merged[0], period: period), before)
    }

    /// The deliberate difference from NoteTask.merge.
    func testHandEnteredCreditsSurviveARefreshThatDoesNotMentionThem() {
        let typed = CardBenefit(title: "Retention offer credit", amount: 50,
                                cycle: .annualCardmember)
        let known = CardBenefit(title: "Lululemon credit", amount: 75, cycle: .quarterly)

        let merged = CardBenefit.merge(catalog: [known], into: [typed, known])

        XCTAssertEqual(merged.count, 2, "the scrape deleted a credit the user typed")
        XCTAssertTrue(merged.contains { $0.id == typed.id })
    }

    func testTitleMatchingIgnoresCaseAndTrailingPunctuation() {
        let existing = CardBenefit(title: "Uber Cash", amount: 15, cycle: .monthly)
        let merged = CardBenefit.merge(
            catalog: [CardBenefit(title: "uber cash.", amount: 15, cycle: .monthly)],
            into: [existing])

        XCTAssertEqual(merged.count, 1, "the same credit was kept twice")
        XCTAssertEqual(merged[0].id, existing.id)
    }

    func testTwoCatalogRowsCannotBothClaimOneExistingBenefit() {
        let existing = CardBenefit(title: "Dining credit", amount: 10, cycle: .monthly)
        let merged = CardBenefit.merge(
            catalog: [CardBenefit(title: "Dining credit", amount: 10, cycle: .monthly),
                      CardBenefit(title: "Dining credit", amount: 10, cycle: .monthly)],
            into: [existing])

        let reused = merged.filter { $0.id == existing.id }
        XCTAssertEqual(reused.count, 1, "one identity was handed to two rows")
    }

    // MARK: - Helpers

    private func makeStatus(cycle: BenefitCycle, now: Date,
                            isRedeemed: Bool = false) -> BenefitStatus {
        let benefit = CardBenefit(title: "Credit", amount: 75, cycle: cycle)
        return BenefitStatus(
            card: HeldCard(issuer: "Test", name: "Card", benefits: [benefit]),
            benefit: benefit,
            period: cycle.period(containing: now, calendar: calendar),
            isRedeemed: isRedeemed)
    }
}

private extension Date {
    func startOfUTCDay(_ calendar: Calendar) -> Date { calendar.startOfDay(for: self) }
}
