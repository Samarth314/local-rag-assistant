import SwiftUI

/// What your cards give you, and what you are about to lose.
///
/// Ordered by deadline, not by card. The question this screen answers is "what
/// expires next", and grouping by card would bury a credit closing on Tuesday
/// under one that runs to December.
struct CardsScreen: View {
    @EnvironmentObject private var state: AppState
    @StateObject private var wallet = CardWallet()
    @State private var catalog = CardCatalog.bundled
    @State private var isPicking = false
    @State private var editing: HeldCard?
    /// Ticks over so the countdown is right on a screen left open past
    /// midnight, without a timer redrawing it every second.
    @State private var now = Date()

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Space.m) {
                if let failure = wallet.failure {
                    // Above everything, and never replaced by the empty state:
                    // "No cards yet" over a file that would not open says the
                    // wallet is empty when it is not.
                    Label(failure, systemImage: "exclamationmark.triangle")
                        .font(.ataruCaption())
                        .foregroundStyle(Theme.amber)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, Theme.Space.s)
                }
                if wallet.cards.isEmpty {
                    if wallet.failure == nil { empty }
                } else {
                    headline
                    ForEach(wallet.statuses(at: now)) { status in
                        BenefitRow(status: status, now: now) { redeemed in
                            wallet.setRedeemed(redeemed, benefit: status.benefit,
                                               period: status.period)
                            Haptics.fire(.selection)
                        }
                    }
                    yourCards
                }
            }
            .padding(.horizontal, Theme.Space.screen)
            .padding(.bottom, Theme.Space.l)
        }
        .navigationTitle("Cards")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { isPicking = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Add a card")
                    .accessibilityIdentifier("add-card")
            }
        }
        .sheet(isPresented: $isPicking) {
            CardPicker(catalog: catalog, held: wallet.cards) { entry in
                wallet.add(entry.held())
                isPicking = false
            }
        }
        .sheet(item: $editing) { card in
            CardEditor(card: card, wallet: wallet)
        }
        .task {
            now = Date()
            // The catalog is an upgrade, never a requirement: a backend without
            // the route leaves the bundled card list in place and the screen
            // works exactly as well, because the amounts were always going to
            // come from the user or the agent, not from this binary.
            if let fetched = try? await state.service.cardCatalog(), !fetched.cards.isEmpty {
                catalog = fetched
                // Fold the refreshed terms into cards already held, keeping
                // every tick and every hand-entered credit. See
                // CardWallet.refresh.
                wallet.refresh(from: fetched)
            }
        }
        .task(id: wallet.redemptions) {
            await BenefitReminders.reschedule(for: wallet.statuses(at: now))
        }
    }

    // MARK: - Pieces

    private var headline: some View {
        ATCard {
            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                SectionLabel(text: "Unclaimed this period")
                Text(wallet.unclaimedValue(at: now),
                     format: .currency(code: "USD").precision(.fractionLength(0)))
                    .font(.ataruTitle())
                    .foregroundStyle(Theme.cyan)
                if let checked = catalog.checkedAt {
                    Text("Card data checked \(checked.formatted(.relative(presentation: .named)))")
                        .font(.ataruCaption())
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Space.m)
        }
    }

    private var yourCards: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            SectionLabel(text: "Your cards")
            ForEach(wallet.cards) { card in
                Button { editing = card } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(card.displayName)
                                .font(.ataruBody())
                                .foregroundStyle(Theme.textPrimary)
                            Text(card.benefits.isEmpty
                                 ? "No credits added yet"
                                 : "\(card.benefits.count) credit\(card.benefits.count == 1 ? "" : "s")")
                                .font(.ataruCaption())
                                .foregroundStyle(Theme.textTertiary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .padding(.vertical, Theme.Space.xs)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, Theme.Space.s)
    }

    private var empty: some View {
        VStack(spacing: Theme.Space.s) {
            Image(systemName: "creditcard")
                .font(.system(size: 34, weight: .ultraLight))
                .foregroundStyle(Theme.cyanSubdued)
            Text("No cards yet")
                .font(.ataruTitle())
                .foregroundStyle(Theme.textPrimary)
            Text("Add the cards you carry and ATARU tracks the credits on them — what is still unspent this quarter, and when it disappears.")
                .font(.ataruCaption())
                .foregroundStyle(Theme.textTertiary)
                .multilineTextAlignment(.center)
            Button("Add a card") { isPicking = true }
                .font(.ataruLabel())
                .foregroundStyle(Theme.cyan)
                .padding(.top, Theme.Space.xs)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Theme.Space.xl)
    }
}

// MARK: - Rows

private struct BenefitRow: View {
    let status: BenefitStatus
    let now: Date
    let setRedeemed: (Bool) -> Void

    var body: some View {
        ATCard {
            HStack(alignment: .top, spacing: Theme.Space.s) {
                Button { setRedeemed(!status.isRedeemed) } label: {
                    Image(systemName: status.isRedeemed
                          ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 21, weight: .light))
                        .foregroundStyle(status.isRedeemed ? Theme.cyan : Theme.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(status.isRedeemed ? "Mark unused" : "Mark used")

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: Theme.Space.xs) {
                        Text(status.benefit.title)
                            .font(.ataruBody())
                            .foregroundStyle(status.isRedeemed
                                             ? Theme.textTertiary : Theme.textPrimary)
                            .strikethrough(status.isRedeemed, color: Theme.textTertiary)
                        Spacer(minLength: 0)
                        if let amount = status.benefit.amount {
                            Text(amount, format: .currency(code: "USD")
                                .precision(.fractionLength(0)))
                                .font(.ataruBody())
                                .foregroundStyle(status.isRedeemed
                                                 ? Theme.textTertiary : Theme.cyan)
                        }
                    }
                    Text(status.card.displayName)
                        .font(.ataruCaption())
                        .foregroundStyle(Theme.textTertiary)
                    deadline
                }
            }
            .padding(Theme.Space.m)
        }
    }

    /// The whole point of the row. Colour earns its place here: a credit with
    /// days left is a different thing from one with months.
    private var deadline: some View {
        let days = status.daysRemaining(from: now)
        let text: String
        let tone: Color

        if status.isRedeemed {
            text = "Used this \(status.benefit.cycle.title.lowercased()) period"
            tone = Theme.textTertiary
        } else if days < 0 {
            text = "Expired"
            tone = Theme.textTertiary
        } else if days == 0 {
            text = "Last day"
            tone = Theme.amber
        } else if days <= 14 {
            text = "\(days) day\(days == 1 ? "" : "s") left"
            tone = Theme.amber
        } else {
            text = "Until \(status.period.end.addingTimeInterval(-1).formatted(.dateTime.month().day()))"
            tone = Theme.textTertiary
        }

        return Text(text)
            .font(.ataruCaption())
            .foregroundStyle(tone)
    }
}

// MARK: - Picker

private struct CardPicker: View {
    let catalog: CardCatalog
    let held: [HeldCard]
    let choose: (CardCatalog.Entry) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(catalog.available(excluding: held)) { entry in
                Button { choose(entry) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(entry.issuer) \(entry.name)")
                            .foregroundStyle(Theme.textPrimary)
                        if !entry.benefits.isEmpty {
                            Text("\(entry.benefits.count) known credit\(entry.benefits.count == 1 ? "" : "s")")
                                .font(.ataruCaption())
                                .foregroundStyle(Theme.textTertiary)
                        }
                    }
                }
            }
            .navigationTitle("Add a card")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Editor

/// Where credits get added by hand.
///
/// Not a fallback for when the agent is late - the primary path for anything
/// the catalog does not know, which will always be some of it. Card terms vary
/// by when you opened the card and what retention offer you took, and the
/// person holding the statement is a better source than a scrape.
private struct CardEditor: View {
    let card: HeldCard
    @ObservedObject var wallet: CardWallet

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var amount = ""
    @State private var cycle: BenefitCycle = .quarterly
    @State private var anniversary: Date
    @State private var hasAnniversary: Bool

    init(card: HeldCard, wallet: CardWallet) {
        self.card = card
        self.wallet = wallet
        _anniversary = State(initialValue: card.anniversary ?? Date())
        _hasAnniversary = State(initialValue: card.anniversary != nil)
    }

    private var live: HeldCard { wallet.cards.first { $0.id == card.id } ?? card }

    var body: some View {
        NavigationStack {
            Form {
                Section("Credits") {
                    ForEach(live.benefits) { benefit in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(benefit.title)
                            Text([benefit.amount.map {
                                    $0.formatted(.currency(code: "USD")
                                        .precision(.fractionLength(0))) },
                                  benefit.cycle.title]
                                .compactMap { $0 }.joined(separator: " · "))
                                .font(.ataruCaption())
                                .foregroundStyle(Theme.textTertiary)
                        }
                    }
                    .onDelete { offsets in
                        offsets.map { live.benefits[$0] }
                            .forEach { wallet.removeBenefit($0, from: live) }
                    }
                }

                Section("Add a credit") {
                    TextField("What it is — e.g. Lululemon credit", text: $title)
                    TextField("Amount in dollars", text: $amount)
                        .keyboardType(.decimalPad)
                    Picker("Resets", selection: $cycle) {
                        ForEach(BenefitCycle.allCases, id: \.self) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    Button("Add") { addBenefit() }
                        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                // Only asked for because it changes the ANSWER, not to be
                // thorough: an anniversary-year credit resolved against the
                // calendar year expires up to eleven months early.
                Section {
                    Toggle("Card has an anniversary date", isOn: $hasAnniversary)
                    if hasAnniversary {
                        DatePicker("Opened", selection: $anniversary,
                                   displayedComponents: .date)
                    }
                } header: {
                    Text("Anniversary")
                } footer: {
                    Text("Needed only for credits that reset on the card's anniversary rather than on 1 January.")
                }
            }
            .navigationTitle(live.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") {
                        wallet.setAnniversary(hasAnniversary ? anniversary : nil, for: live)
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Remove card", role: .destructive) {
                        wallet.remove(live)
                        dismiss()
                    }
                    .foregroundStyle(Theme.amber)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func addBenefit() {
        guard let name = title.nilIfBlank else { return }
        wallet.addBenefit(
            CardBenefit(title: name,
                        amount: Decimal(string: amount.filter { $0.isNumber || $0 == "." }),
                        cycle: cycle),
            to: live)
        title = ""
        amount = ""
    }
}
