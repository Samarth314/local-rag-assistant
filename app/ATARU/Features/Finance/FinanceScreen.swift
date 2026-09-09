import SwiftUI

/// The three pages of Finance: what was spent, what the cards owe you, and
/// what still has to be collected.
///
/// ## Why Cards stopped being a tile of its own
///
/// It was one, and the launcher paid for it: every tile in the fan costs the
/// ones around it room, and Cards is the same subject as Finance seen from a
/// different angle. Three pages behind one orb is one destination to reach for
/// and a swipe to get between them, which is cheaper than a second sweep of
/// the dial - and it puts the statement checklist somewhere it will actually
/// be seen, next to the numbers it feeds.
enum FinancePage: String, CaseIterable, Identifiable {
    case overview, cards, statements

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview:   return "Overview"
        case .cards:      return "Cards"
        case .statements: return "Statements"
        }
    }
}

/// Where a request to open Finance on a particular page waits until Finance
/// exists to receive it.
///
/// Same shape as `PendingNotificationRoute`, and for the same reason: the thing
/// that decides the destination (a launch argument, a routed notification) runs
/// before the page is on screen, so it leaves the answer here and the page
/// takes it once. `.cards` used to be a `HomeTile` and anything still asking
/// for it by that name lands on page two rather than nowhere.
enum FinanceRoute {
    /// The raw value the Cards tile used to answer to.
    static let retiredCardsTile = "cards"

    private static var page: FinancePage?

    static func record(_ destination: FinancePage) { page = destination }

    static func take() -> FinancePage? {
        defer { page = nil }
        return page
    }
}

struct FinanceScreen: View {
    @EnvironmentObject private var state: AppState
    /// One fetch of the checklist, read by two pages. See StatementsModel.
    @StateObject private var statements = StatementsModel()
    @State private var page: FinancePage = .overview
    /// Reported up from Overview, because the demo marker belongs in the
    /// navigation title and the flag that decides it arrives in Overview's
    /// payload.
    @State private var overviewIsDemoBackend = false

    var body: some View {
        VStack(spacing: 0) {
            FinancePageIndicator(selection: $page)

            // A page-style TabView, which is what makes the swipe between the
            // three feel like one screen rather than three pushes.
            //
            // THE PAGES OWN NO NAVIGATION CHROME. A toolbar declared inside a
            // page is merged into the bar by every page the pager keeps alive,
            // not only the visible one, so the Cards "+" would appear over
            // Overview and flicker on every swipe. The title and the bar are
            // decided here, once, from `page`.
            TabView(selection: $page) {
                FinanceOverviewScreen(statements: statements,
                                      isDemoBackend: $overviewIsDemoBackend,
                                      openStatements: { go(to: .statements) })
                    .tag(FinancePage.overview)

                CardsScreen(isEmbedded: true)
                    .tag(FinancePage.cards)

                StatementsPage(model: statements)
                    .tag(FinancePage.statements)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
        .ataruBackdrop()
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: state.onlineGeneration) {
            statements.configure(
                root: TileBackend.current(from: state).apiRoot(.finance),
                isDemo: state.isDemo)
            // Loaded here rather than on the Statements page, so the "N
            // missing" chip on Overview is right the moment Finance opens.
            await statements.restore()
            await statements.load()
        }
        .task {
            if let wanted = FinanceRoute.take() { page = wanted }
        }
    }

    private var navigationTitle: String {
        switch page {
        case .overview:   return overviewIsDemoBackend ? "Finance (demo)" : "Finance"
        case .cards:      return "Cards"
        case .statements: return "Statements"
        }
    }

    private func go(to destination: FinancePage) {
        withAnimation(Theme.spring) { page = destination }
    }
}

// MARK: - The indicator

/// Which of the three you are on, and a way there without swiping.
///
/// Dots were the obvious thing and are the wrong thing here: three anonymous
/// dots say how many pages exist and nothing about what is on them, and they
/// cannot be tapped by VoiceOver. Three labels carry the same position
/// information, name the destinations, and double as the accessible route
/// between them - which the swipe itself is not.
private struct FinancePageIndicator: View {
    @Binding var selection: FinancePage
    @Namespace private var underline

    var body: some View {
        HStack(spacing: Theme.Space.l) {
            ForEach(FinancePage.allCases) { page in
                Button {
                    withAnimation(Theme.spring) { selection = page }
                } label: {
                    VStack(spacing: 5) {
                        Text(page.title.uppercased())
                            .font(Ataru.TextStyle.tag.font)
                            .tracking(Ataru.TextStyle.tag.tracking)
                            .foregroundStyle(page == selection
                                             ? Theme.cyan : Theme.textTertiary)
                        Group {
                            if page == selection {
                                Capsule()
                                    .fill(Theme.cyan)
                                    .frame(height: 1.5)
                                    .matchedGeometryEffect(id: "underline",
                                                           in: underline)
                            } else {
                                Color.clear.frame(height: 1.5)
                            }
                        }
                    }
                    .contentShape(Rectangle())
                    .frame(minHeight: Theme.minHitTarget)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(page.title)
                .accessibilityAddTraits(page == selection
                                        ? [.isButton, .isSelected] : .isButton)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Space.screen)
        .accessibilityElement(children: .contain)
    }
}
