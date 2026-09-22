import SwiftUI

/// The three pages of Gym: what is on today, what the routines are, and what
/// has already been done.
///
/// ## Why this is a screen of the app's own and no longer a web page
///
/// It used to be openGym in a Safari sheet, because openGym signs in with a
/// passkey and a passkey cannot be held by an app. It still cannot - what
/// changed is that the phone no longer needs one. The ATARU server reaches the
/// same state document through a bridge on the orin (see the vault's
/// records/work/opengym/APP-API.md), so the app talks to its own backend with
/// its own bearer token and the browser keeps its passkey.
///
/// What that buys is not tidiness. It is a screen that renders the last known
/// state with no network at all, prefills a set from the last time the
/// exercise was actually done, keeps a session in progress across a locked
/// phone, and looks like the rest of the app while doing it.
enum GymPage: String, CaseIterable, Identifiable {
    case today, routines, history

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today:    return "Today"
        case .routines: return "Routines"
        case .history:  return "History"
        }
    }
}

struct GymScreen: View {
    @EnvironmentObject private var state: AppState
    @StateObject private var store = GymStore()
    @Environment(\.scenePhase) private var scenePhase
    @State private var page: GymPage = .today
    @State private var isWorkingOut = false

    var body: some View {
        VStack(spacing: 0) {
            GymPageIndicator(selection: $page)

            // A page-style TabView, like Finance: three pages behind one orb,
            // and a swipe between them rather than a second sweep of the dial.
            // The pages own no navigation chrome - a toolbar declared inside
            // one is merged into the bar by every page the pager keeps alive.
            TabView(selection: $page) {
                GymTodayPage(store: store, startWorkout: openWorkout)
                    .tag(GymPage.today)

                GymRoutinesPage(store: store)
                    .tag(GymPage.routines)

                GymHistoryPage(store: store)
                    .tag(GymPage.history)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
        .ataruBackdrop()
        // Every numeric field on these three pages can be put away: tap off
        // it, drag the page, or use the Done bar above the keys. The number
        // pad has no return key, so without this it stays up until something
        // else resigns first responder - and on these pages nothing did.
        .dismissableNumberPads()
        .navigationTitle(page == .today ? "Gym" : page.title)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $isWorkingOut) {
            ActiveWorkoutView(store: store)
        }
        .task(id: state.serviceGeneration) {
            store.configure(service: state.service,
                            cacheRoot: state.isDemo ? nil : state.configuration.baseURL)
            await store.restore()
            await store.refresh()
            // The catalogue: once per launch, off disk for a day, and
            // separately from the document because it is openGym's build
            // artefact rather than Arya's data. After the document and not
            // beside it, so the plan is on screen first; failing is silent -
            // the screens render ids and placeholders, which is what they did
            // before there was a library at all.
            await store.loadLibrary()
        }
        // Back on the network after an outage - the same key every other
        // screen uses.
        .task(id: state.onlineGeneration) {
            guard state.onlineGeneration > 0 else { return }
            await store.refreshIfChanged()
        }
        // Back in the foreground. The cheap poll, not the whole document: one
        // request that answers whether anything moved, and the day itself may
        // have rolled over while the phone was in a pocket.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await store.refreshIfChanged() }
        }
    }

    /// Start a routine, or go back to the one already running.
    ///
    /// The routine comes from the page, because the page is what now decides
    /// which one - next up, or whatever the picker returned. A session already
    /// in progress is never rebuilt: whatever is on this phone is the only
    /// copy of it, and the card's Resume has to mean resume.
    private func openWorkout(_ routineID: String) {
        if store.active == nil { store.startWorkout(routineID: routineID) }
        isWorkingOut = true
    }
}

// MARK: - The indicator

/// Which of the three you are on, and a way there without swiping. Three
/// labels rather than three dots, for the reasons written up in
/// `FinancePageIndicator`: dots name nothing and VoiceOver cannot tap them.
private struct GymPageIndicator: View {
    @Binding var selection: GymPage
    @Namespace private var underline

    var body: some View {
        HStack(spacing: Theme.Space.l) {
            ForEach(GymPage.allCases) { page in
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
                                    .matchedGeometryEffect(id: "underline", in: underline)
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

// MARK: - Formatting

/// Weights and counts, written the way the document stores them.
enum GymFormat {

    /// 80, not 80.0 - and 82.5 when it really is. openGym keeps both in the
    /// same field and a screen full of trailing zeros reads as a different
    /// number from the one on the bar.
    static func number(_ value: Double) -> String {
        value.rounded() == value
            ? String(Int(value))
            : String(format: "%.1f", value)
    }

    static func weight(_ value: Double?, unit: String) -> String {
        guard let value else { return "-" }
        if value == 0 { return "bodyweight" }
        return "\(number(value)) \(unit)"
    }

    /// A weight out of the document, written in POUNDS.
    ///
    /// Conversion and formatting in ONE call on purpose. The document's unit
    /// is whatever openGym's settings last left it at, so every weight on
    /// every screen needs the same two steps in the same order - and a pair of
    /// separate helpers is an invitation to convert twice on one screen and
    /// not at all on the next. There is no call site in this app that formats
    /// a weight without converting it.
    static func weightInPounds(_ value: Double?, storedIn unit: String) -> String {
        weight(GymUnits.toDisplay(value, storedIn: unit), unit: GymUnits.display)
    }

    /// The same, for the places that write the unit themselves - a bodyweight
    /// row, a chart's caption - where zero is a real reading rather than
    /// openGym's "bodyweight" sentinel.
    static func numberInPounds(_ value: Double, storedIn unit: String) -> String {
        number(GymUnits.toDisplay(value, storedIn: unit) ?? value)
    }

    /// How long ago a routine was last trained: "today", "yesterday", "3 d
    /// ago" - and "never" for one that has not been.
    ///
    /// "never" is a real answer and is said plainly. A dash, or an empty cell,
    /// reads as missing data on a picker whose whole job is to say which
    /// routine is overdue.
    ///
    /// Whole days apart in the phone's own calendar, not hours divided by 24:
    /// a session at 21:00 yesterday and a glance at 08:00 today is one day
    /// apart to a human and zero to the arithmetic.
    static func since(_ day: String?, now: Date = Date()) -> String {
        guard let day, let date = GymClock.date(fromDay: day) else { return "never" }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let from = calendar.startOfDay(for: date)
        let to = calendar.startOfDay(for: now)
        guard let days = calendar.dateComponents([.day], from: from, to: to).day else {
            return "never"
        }
        switch days {
        case ..<0:  return "ahead"      // a day in the future: say so, do not lie about it
        case 0:     return "today"
        case 1:     return "yesterday"
        default:    return "\(days) d ago"
        }
    }

    /// "3 x 10", the way a routine reads on paper.
    static func target(sets: Int?, reps: Int?) -> String {
        guard let sets else { return "" }
        guard let reps else { return "\(sets) set\(sets == 1 ? "" : "s")" }
        return "\(sets) x \(reps)"
    }

    static func day(_ iso: String) -> String {
        guard let date = GymClock.date(fromDay: iso) else { return iso }
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("EEE d MMM")
        return formatter.string(from: date)
    }
}

// MARK: - Shared chrome

/// The one line the Gym pages owe the user about their own freshness.
///
/// It is a badge rather than a banner because it is true all the time: a
/// screen that can be read offline should say so quietly and get out of the
/// way, and the only state worth interrupting for is a write that failed.
struct GymSyncBadge: View {
    let sync: GymSyncState

    var body: some View {
        if case .idle = sync {
            EmptyView()
        } else {
            HStack(spacing: Theme.Space.xs) {
                StatusDot(tone: sync.tone, label: sync.label)
                if case .unavailable(let detail) = sync {
                    Text(detail)
                        .font(.ataruCaption())
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(2)
                } else if case .offline(let at) = sync, let at {
                    Text("last synced \(at.formatted(date: .omitted, time: .shortened))")
                        .font(.ataruCaption())
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        }
    }
}
