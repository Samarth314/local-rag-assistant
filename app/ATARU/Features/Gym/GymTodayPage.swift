import SwiftUI

/// Page one: what is on today, and the one button that starts it.
///
/// The order is the order of the morning - what day it is, what is planned,
/// start, and the weigh-in. Everything else about openGym is a swipe away.
struct GymTodayPage: View {
    @ObservedObject var store: GymStore
    let startWorkout: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                GymSyncBadge(sync: store.sync)

                if let message = store.errorMessage {
                    ErrorBanner(message: message)
                }

                weekStrip
                todayCard
                bodyweightCard
            }
            .padding(Theme.Space.screen)
        }
        .refreshable { await store.refresh() }
    }

    // MARK: - The week

    /// Monday to Sunday, with the routine's letter under each day.
    ///
    /// Monday first because `weekStart` says so and because that is how the
    /// split is written down - but the LOOKUP is by Javascript's weekday, 0 =
    /// Sunday, which is what the document is keyed by. Those are two different
    /// things and conflating them is how a Monday shows Tuesday's routine.
    private var weekStrip: some View {
        ATCard {
            HStack(spacing: 0) {
                ForEach(weekdayOrder, id: \.self) { weekday in
                    VStack(spacing: 6) {
                        Text(shortWeekdayName(weekday))
                            .font(.ataruCaption())
                            .foregroundStyle(weekday == todayWeekday
                                             ? Theme.cyan : Theme.textTertiary)
                        ZStack {
                            Circle()
                                .fill(weekday == todayWeekday
                                      ? Theme.accentSoft : Color.clear)
                                .overlay {
                                    Circle().strokeBorder(
                                        weekday == todayWeekday
                                            ? Theme.cyanSubdued : Color.clear,
                                        lineWidth: 1)
                                }
                                .frame(width: 30, height: 30)
                            Text(letter(for: weekday))
                                .font(.ataruBody())
                                .foregroundStyle(letter(for: weekday) == "-"
                                                 ? Theme.textTertiary
                                                 : Theme.textPrimary)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(accessibleWeekday(weekday))
                }
            }
            .padding(Theme.Space.m)
        }
    }

    /// Monday first, Sunday last, in Javascript's numbering.
    private var weekdayOrder: [Int] { [1, 2, 3, 4, 5, 6, 0] }

    private var todayWeekday: Int { GymClock.jsWeekday(Date()) }

    private func shortWeekdayName(_ weekday: Int) -> String {
        String(GymToday.weekdayNames[weekday].prefix(1))
            + String(GymToday.weekdayNames[weekday].dropFirst().prefix(1))
    }

    private func letter(for weekday: Int) -> String {
        guard let state = store.state, let id = state.weekRoutineID(weekday: weekday),
              let routine = state.routine(id: id) else { return "-" }
        return routine.shortLabel
    }

    private func accessibleWeekday(_ weekday: Int) -> String {
        let name = GymToday.weekdayNames[weekday]
        guard let state = store.state, let id = state.weekRoutineID(weekday: weekday),
              let routine = state.routine(id: id) else { return "\(name), rest" }
        return "\(name), \(routine.name)"
    }

    // MARK: - Today

    @ViewBuilder
    private var todayCard: some View {
        ATCard {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                header

                if case .unavailable(let detail) = store.sync, store.state == nil {
                    // NEVER a rest day. "openGym is off" and "the orin is
                    // down" are claims about the server, and drawing either as
                    // an empty plan is a claim about Arya's week.
                    Text(detail)
                        .font(.ataruCaption())
                        .foregroundStyle(Theme.amber)
                } else if let today = store.today {
                    if let routine = today.routine {
                        exercises(routine)
                        startButton(routine)
                    } else {
                        Text(restLine)
                            .font(.ataruCaption())
                            .foregroundStyle(Theme.textTertiary)
                    }
                } else if store.state == nil {
                    ProgressView()
                        .tint(Theme.cyan)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Theme.Space.s)
                }
            }
            .padding(Theme.Space.m)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                SectionHeader(text: store.today?.weekday ?? "Today")
                Text(title)
                    .font(.ataruTitle())
                    .foregroundStyle(Theme.textPrimary)
            }
            Spacer()
            if let last = lastTrained {
                Text(last)
                    .font(.ataruCaption())
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }

    private var title: String {
        guard let today = store.today else { return "-" }
        guard let routine = today.routine else {
            return isDeclaredRest ? "Rest day" : "Nothing planned"
        }
        // A plan pointing at a routine that has been deleted: say so rather
        // than drawing an empty day, which reads as a rest day.
        return routine.name ?? "Routine \(routine.id) is missing"
    }

    private var isDeclaredRest: Bool {
        guard let state = store.state, let today = store.today else { return false }
        return state.isDeclaredRest(on: today.date)
    }

    private var restLine: String {
        isDeclaredRest
            ? "A rest day, on purpose."
            : "Nothing on the plan for today."
    }

    private var lastTrained: String? {
        guard let workout = store.today?.lastWorkout, !workout.day.isEmpty else {
            return nil
        }
        return "last \(GymFormat.day(workout.day))"
    }

    @ViewBuilder
    private func exercises(_ routine: GymToday.Routine) -> some View {
        if routine.exercises.isEmpty {
            Text("This routine has no exercises yet.")
                .font(.ataruCaption())
                .foregroundStyle(Theme.textTertiary)
        } else {
            VStack(spacing: Theme.Space.xs) {
                // Keyed by position: an exercise can legitimately appear twice
                // in a routine, and a ForEach handed the same id twice draws
                // one row.
                ForEach(Array(routine.exercises.enumerated()), id: \.offset) { _, exercise in
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(exercise.name ?? exercise.id)
                                .font(.ataruBody())
                                .foregroundStyle(Theme.textPrimary)
                            Text(GymFormat.target(sets: exercise.sets,
                                                  reps: exercise.reps))
                                .font(.ataruCaption())
                                .foregroundStyle(Theme.textTertiary)
                        }
                        Spacer(minLength: Theme.Space.s)
                        Text(lastWeightLine(exercise))
                            .font(.ataruMono(11))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .padding(.vertical, 2)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    /// What was actually lifted last time, not what the routine says. The
    /// routine's weight is a plan; this is the number he beat or did not.
    private func lastWeightLine(_ exercise: GymToday.Exercise) -> String {
        if let entry = store.today?.lastWorkout?.entry(forExercise: exercise.id),
           let weight = entry.heaviestCompleted {
            return GymFormat.weight(weight, unit: unit)
        }
        if let weight = exercise.weight {
            return GymFormat.weight(weight, unit: unit)
        }
        return "-"
    }

    private var unit: String { store.state?.unit ?? "kg" }

    @ViewBuilder
    private func startButton(_ routine: GymToday.Routine) -> some View {
        let resuming = store.active != nil
        Button(action: startWorkout) {
            HStack(spacing: Theme.Space.xs) {
                Image(systemName: resuming ? "arrow.clockwise" : "play.fill")
                    .font(.system(size: 13, weight: .semibold))
                Text(resuming ? "Resume workout" : "Start workout")
                    .font(.ataruBody())
            }
            .foregroundStyle(Theme.onAccent)
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background {
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .fill(Theme.cyan)
            }
        }
        .buttonStyle(.atPress)
        .padding(.top, Theme.Space.xs)
        .disabled(routine.exercises.isEmpty)
        .accessibilityHint(resuming
            ? "Go back to the session already in progress."
            : "Log sets for \(routine.name ?? "this routine").")
    }

    // MARK: - Bodyweight

    private var bodyweightCard: some View {
        ATCard {
            GymBodyweightRow(store: store)
                .padding(Theme.Space.m)
        }
    }
}

/// The weigh-in, as one row.
///
/// One entry per calendar day, so entering a second number today REPLACES
/// today's rather than appending - two entries for one day is what makes two
/// devices disagree after a merge.
struct GymBodyweightRow: View {
    @ObservedObject var store: GymStore
    @State private var draft = ""
    @FocusState private var isEditing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(alignment: .firstTextBaseline) {
                SectionHeader(text: "Body weight")
                Spacer()
                if let latest = store.state?.bodyweight.first {
                    Text("\(GymFormat.number(latest.weight)) \(unit) · \(GymFormat.day(latest.day))")
                        .font(.ataruCaption())
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            HStack(spacing: Theme.Space.s) {
                TextField("today", text: $draft)
                    .keyboardType(.decimalPad)
                    .font(.ataruBody())
                    .foregroundStyle(Theme.textPrimary)
                    .focused($isEditing)
                    .padding(.horizontal, Theme.Space.s)
                    .frame(height: Theme.minHitTarget)
                    .background {
                        RoundedRectangle(cornerRadius: Theme.Radius.small,
                                         style: .continuous)
                            .fill(Theme.surfaceElevated)
                    }
                    .accessibilityLabel("Body weight in \(unit)")

                Button("Save") { Task { await save() } }
                    .font(.ataruBody())
                    .foregroundStyle(canSave ? Theme.cyan : Theme.textTertiary)
                    .frame(minHeight: Theme.minHitTarget)
                    .disabled(!canSave)
            }
        }
    }

    private var unit: String { store.state?.unit ?? "kg" }

    private var value: Double? {
        Double(draft.replacingOccurrences(of: ",", with: "."))
    }

    private var canSave: Bool {
        guard let value else { return false }
        // A plain sanity bound, not a health judgement: it exists to catch a
        // fat-fingered 700 before it reaches the log.
        return value > 0 && value < 500 && !store.isSaving && !store.sync.isReadOnly
    }

    private func save() async {
        guard let value else { return }
        isEditing = false
        if await store.recordBodyweight(value) { draft = "" }
    }
}
