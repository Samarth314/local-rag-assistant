import SwiftUI

/// Page one: what is on today, and the one button that starts it.
///
/// The order is the order of the morning - what day it is, what is planned,
/// start, and the weigh-in. Everything else about openGym is a swipe away.
struct GymTodayPage: View {
    @ObservedObject var store: GymStore
    let startWorkout: () -> Void

    @State private var isConfirmingDiscard = false

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
        .confirmationDialog("Discard the workout in progress?",
                            isPresented: $isConfirmingDiscard,
                            titleVisibility: .visible) {
            Button("Discard", role: .destructive) { store.discardWorkout() }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text("It only exists on this phone and nothing has been sent to "
                 + "openGym, so it would be gone.")
        }
    }

    // MARK: - The week

    /// Monday to Sunday, with one character per day and today's full routine
    /// name written out underneath.
    ///
    /// Monday first because `weekStart` says so and because that is how the
    /// split is written down - but the LOOKUP is by Javascript's weekday, 0 =
    /// Sunday, which is what the document is keyed by. Those are two different
    /// things and conflating them is how a Monday shows Tuesday's routine.
    ///
    /// ## Why every measurement here is fixed
    ///
    /// On the demo fixture this strip looked right and on Arya's own document
    /// it did not: "the week view doesn't render text properly, stuff is
    /// staggered instead of all the same level, and barbell isn't even fitting
    /// on one line, the circle around abs is hugging way too close."
    ///
    /// One cause, three symptoms. `GymRoutine.shortLabel` returned openGym's
    /// `emoji` field verbatim, and that field holds an ICON NAME, not an emoji
    /// - `"barbell"`, `"pullup"`, `"abs"`. A seven-word strip in a
    /// seven-column HStack wraps; a wrapped label is taller than an unwrapped
    /// one, so the cells stopped sharing a baseline; and the ring, which was
    /// sized to the circle but drawn in a ZStack that the text could outgrow,
    /// ended up tight around the word.
    ///
    /// `shortLabel` is fixed at the source. This strip is then built so that
    /// no label CAN do it again: a fixed cell height, a fixed 30pt ring, one
    /// line, and a scale floor rather than a wrap. A cell that cannot change
    /// height cannot stagger the row.
    private var weekStrip: some View {
        ATCard {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                HStack(spacing: 0) {
                    ForEach(weekdayOrder, id: \.self) { weekday in
                        dayCell(weekday)
                    }
                }
                // Nothing is hidden by shortening the labels: today's routine
                // is named in full, right here, in the one place a name is
                // actually worth the width.
                Text(todayLine)
                    .font(.ataruCaption())
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityHidden(true)
            }
            .padding(Theme.Space.m)
        }
    }

    /// One day. Two fixed-height rows, so every cell in the strip is the same
    /// height whatever is in it.
    private func dayCell(_ weekday: Int) -> some View {
        let isToday = weekday == todayWeekday
        let token = letter(for: weekday)
        return VStack(spacing: 6) {
            Text(shortWeekdayName(weekday))
                .font(.ataruCaption())
                .lineLimit(1)
                .foregroundStyle(isToday ? Theme.cyan : Theme.textTertiary)
                .frame(height: Self.weekdayRowHeight)

            ZStack {
                // A ring of a FIXED size, drawn behind the label rather than
                // around it. Nothing the label does can make it hug.
                Circle()
                    .fill(isToday ? Theme.accentSoft : Color.clear)
                    .overlay {
                        Circle().strokeBorder(isToday ? Theme.cyanSubdued : Color.clear,
                                              lineWidth: 1)
                    }
                    .frame(width: Self.ringSize, height: Self.ringSize)

                Text(token)
                    .font(.ataruBody())
                    .foregroundStyle(token == Self.restToken
                                     ? Theme.textTertiary : Theme.textPrimary)
                    // One line, and a floor rather than a wrap: a label that
                    // somehow arrives long shrinks inside the ring instead of
                    // growing the cell.
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .frame(width: Self.ringSize - 8)
            }
            .frame(height: Self.ringSize)
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.cellHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibleWeekday(weekday))
    }

    /// The strip's whole geometry, in one place, so "the same level" is a
    /// property of the layout rather than of what the labels happen to be.
    private static let ringSize: CGFloat = 30
    private static let weekdayRowHeight: CGFloat = 16
    private static let cellHeight: CGFloat = weekdayRowHeight + 6 + ringSize
    static let restToken = "-"

    /// Today's routine, written out - or why there isn't one.
    private var todayLine: String {
        guard let state = store.state else { return "" }
        guard let id = state.routineID(on: GymClock.day()),
              let routine = state.routine(id: id), !routine.name.isEmpty else {
            return state.isDeclaredRest(on: GymClock.day())
                ? "Today: rest day" : "Today: nothing planned"
        }
        return "Today: \(routine.name)"
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
              let routine = state.routine(id: id) else { return Self.restToken }
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
                    HStack(spacing: Theme.Space.s) {
                        // Tap the demo, not the row: the row itself is a
                        // reading of today's plan and has nowhere else to go.
                        NavigationLink {
                            GymExerciseDetail(
                                name: store.displayName(for: exercise.id,
                                                        fallback: exercise.name),
                                entry: store.libraryEntry(for: exercise.id),
                                gifURL: store.gifURL(forExercise: exercise.id))
                        } label: {
                            GymExerciseThumbnail(url: store.gifURL(forExercise: exercise.id),
                                                 side: 36)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Show \(store.displayName(for: exercise.id, fallback: exercise.name))")

                        VStack(alignment: .leading, spacing: 1) {
                            Text(store.displayName(for: exercise.id,
                                                   fallback: exercise.name))
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

    /// Start, or resume - and, when there is something to resume, a way to end
    /// it for good.
    ///
    /// "He started Ayush C, backed out, and now sees Resume workout with no
    /// way to abandon it." A session in progress lives only on this phone
    /// (openGym deletes `active` on every write), so the only control that can
    /// end one is here, and until now there wasn't one: backing out of the
    /// session screen left the file, and the card offered Resume forever.
    ///
    /// Side by side rather than a menu, because Resume is the thing he wants
    /// in the gym and Discard is the thing he wants exactly once - and behind
    /// a confirmation, because a discard cannot be undone from anywhere.
    @ViewBuilder
    private func startButton(_ routine: GymToday.Routine) -> some View {
        let resuming = store.active != nil
        HStack(spacing: Theme.Space.s) {
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
            .disabled(routine.exercises.isEmpty)
            .accessibilityHint(resuming
                ? "Go back to the session already in progress."
                : "Log sets for \(routine.name ?? "this routine").")

            if resuming {
                Button(role: .destructive) {
                    isConfirmingDiscard = true
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 15, weight: .light))
                        .foregroundStyle(Theme.red)
                        .frame(width: 48, height: 48)
                        .background {
                            RoundedRectangle(cornerRadius: Theme.Radius.card,
                                             style: .continuous)
                                .fill(Theme.surfaceElevated)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Discard workout")
                .accessibilityHint("Throw away the session in progress.")
            }
        }
        .padding(.top, Theme.Space.xs)
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
