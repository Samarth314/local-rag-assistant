import SwiftUI

/// Page one: what to do next, and the one button that starts it.
///
/// ## Why this page leads with a routine and not with the calendar
///
/// It used to render the day's plan: whatever `week` said, and on a day the
/// week said nothing about, a sentence saying so and no button at all. Then
/// Arya trained on a Sunday.
///
/// "I worked out yesterday but the app had no way of me selecting a routine
/// and doing it today. I ended up doing Ayush A yesterday."
///
/// Sunday is the split's rest day, so the page showed rest and offered him
/// nothing - not the planned routine, because there wasn't one, and not any
/// other routine, because the screen had never had a way to name one. He
/// trained anyway and the app recorded none of it.
///
/// So the card leads with ONE routine and a button that starts it, every day
/// of the week. A rest day is a NOTE on that card and never a lock: the
/// calendar can say what it likes about Sunday, and a man standing in a gym
/// on a Sunday is still standing in a gym.
///
/// The order is the order of the morning - what the week looks like, what is
/// next, start, and the weigh-in. Everything else about openGym is a swipe
/// away.
struct GymTodayPage: View {
    @ObservedObject var store: GymStore
    /// Starts (or resumes) a session for a routine and pushes the session
    /// screen. Takes the routine, because the page now decides which one -
    /// see the class comment.
    let startWorkout: (String) -> Void

    @State private var isConfirmingDiscard = false
    @State private var isPickingRoutine = false
    @State private var isLoggingPast = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                GymSyncBadge(sync: store.sync)

                if let message = store.errorMessage {
                    ErrorBanner(message: message)
                }

                weekStrip
                nextUpCard
                bodyweightCard
            }
            .padding(Theme.Space.screen)
        }
        .refreshable { await store.refresh() }
        // Sheets rather than pushes: both are a detour from the page, both are
        // finished in one action, and neither belongs in the back stack of a
        // pager whose three pages share one navigation bar.
        .sheet(isPresented: $isPickingRoutine) {
            GymRoutinePicker(store: store) { routineID in
                isPickingRoutine = false
                startWorkout(routineID)
            }
        }
        .sheet(isPresented: $isLoggingPast) {
            GymPastWorkoutForm(store: store)
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

    /// What the CALENDAR has on today, written out - or that it has nothing.
    ///
    /// This strip is the week as it is written down. It is no longer what
    /// decides what can be started (see the card), so the line says "planned"
    /// rather than stating the day's routine as a fact.
    private var todayLine: String {
        guard let state = store.state else { return "" }
        guard let id = state.routineID(on: GymClock.day()),
              let routine = state.routine(id: id), !routine.name.isEmpty else {
            return state.isDeclaredRest(on: GymClock.day())
                ? "Planned today: rest day" : "Planned today: nothing"
        }
        return "Planned today: \(routine.name)"
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

    // MARK: - Next up

    @ViewBuilder
    private var nextUpCard: some View {
        ATCard {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                header

                if case .unavailable(let detail) = store.sync, store.state == nil {
                    // NEVER a rest day, and never an empty card. "openGym is
                    // off" and "the orin is down" are claims about the server,
                    // and drawing either as a plan is a claim about Arya's
                    // week.
                    Text(detail)
                        .font(.ataruCaption())
                        .foregroundStyle(Theme.amber)
                } else if let routine = shownRoutine {
                    if let note = restNote {
                        // Quiet, and one line. A rest day is worth saying and
                        // is not worth a colour, an icon or a disabled button.
                        Text(note)
                            .font(.ataruCaption())
                            .foregroundStyle(Theme.textTertiary)
                    }
                    exercises(routine)
                    startButton(routine)
                } else if store.state == nil {
                    ProgressView()
                        .tint(Theme.cyan)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Theme.Space.s)
                } else {
                    // A profile with no routines at all. Not a rest day
                    // either - there is nothing to rest from yet.
                    Text("No routines yet. Create one in openGym and it shows "
                         + "up here.")
                        .font(.ataruCaption())
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(Theme.Space.m)
        }
    }

    /// The routine the card is about: the session already in progress if there
    /// is one, otherwise whatever is next up.
    ///
    /// Resume wins over next-up deliberately. A session in progress lives only
    /// on this phone, so a card that quietly offered a different routine over
    /// the top of it would be offering to lose it.
    private var shownRoutine: GymRoutine? {
        if let active = store.active,
           let routine = store.state?.routine(id: active.routineID) {
            return routine
        }
        return store.nextRoutine
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                SectionHeader(text: store.active == nil ? "Next up" : "In progress")
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
            overflow
        }
    }

    /// The one thing on this card that is not about starting a workout.
    private var overflow: some View {
        Menu {
            Button {
                isLoggingPast = true
            } label: {
                Label("Log a past workout", systemImage: "calendar.badge.plus")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 16, weight: .light))
                .foregroundStyle(Theme.textSecondary)
                .hitTarget()
        }
        .accessibilityLabel("More")
    }

    private var title: String {
        guard store.state != nil else { return "-" }
        guard let routine = shownRoutine else { return "Nothing to do yet" }
        return routine.name.isEmpty ? "Routine \(routine.id)" : routine.name
    }

    /// The rest-day line, or nil on a day the week has something on.
    ///
    /// This is the ONLY thing `week` is still consulted for on this card, and
    /// it is a sentence rather than a state: the button below it is identical
    /// either way. `dayPlan`'s deliberate "rest" and a weekday the split
    /// simply leaves out are worded differently, because they are different
    /// things - one is a decision and the other is the shape of the split.
    private var restNote: String? {
        guard let state = store.state, store.active == nil else { return nil }
        let day = GymClock.day()
        guard state.routineID(on: day) == nil else { return nil }
        let weekday = GymClock.date(fromDay: day)
            .map { GymToday.weekdayNames[GymClock.jsWeekday($0)] } ?? "Today"
        return state.isDeclaredRest(on: day)
            ? "\(weekday) is a rest day."
            : "Nothing on the plan for \(weekday.lowercased())."
    }

    private var lastTrained: String? {
        guard let routine = shownRoutine, let state = store.state else { return nil }
        guard let day = state.lastDay(forRoutine: routine.id) else { return "never done" }
        return "last \(GymFormat.day(day))"
    }

    @ViewBuilder
    private func exercises(_ routine: GymRoutine) -> some View {
        if routine.exercises.isEmpty {
            Text("This routine has no exercises yet.")
                .font(.ataruCaption())
                .foregroundStyle(Theme.textTertiary)
        } else {
            VStack(spacing: Theme.Space.xs) {
                // Keyed by position: an exercise can legitimately appear twice
                // in a routine, and a ForEach handed the same id twice draws
                // one row.
                ForEach(Array(routine.exercises.enumerated()), id: \.offset) { _, config in
                    HStack(spacing: Theme.Space.s) {
                        // Tap the demo, not the row: the row itself is a
                        // reading of the plan and has nowhere else to go.
                        NavigationLink {
                            GymExerciseDetail(
                                name: store.displayName(for: config.id),
                                entry: store.libraryEntry(for: config.id),
                                gifURL: store.gifURL(forExercise: config.id))
                        } label: {
                            GymExerciseThumbnail(url: store.gifURL(forExercise: config.id),
                                                 side: 36)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Show \(store.displayName(for: config.id))")

                        VStack(alignment: .leading, spacing: 1) {
                            Text(store.displayName(for: config.id))
                                .font(.ataruBody())
                                .foregroundStyle(Theme.textPrimary)
                            Text(GymFormat.target(sets: config.sets, reps: config.reps))
                                .font(.ataruCaption())
                                .foregroundStyle(Theme.textTertiary)
                        }
                        Spacer(minLength: Theme.Space.s)
                        Text(lastWeightLine(routine: routine, config: config))
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
    ///
    /// In pounds, whatever the document stores - see `GymUnits`.
    private func lastWeightLine(routine: GymRoutine,
                                config: GymExerciseConfig) -> String {
        let unit = store.documentUnit
        if let entry = store.state?.lastWorkout(forRoutine: routine.id)?
            .entry(forExercise: config.id),
           let weight = entry.heaviestCompleted {
            return GymFormat.weightInPounds(weight, storedIn: unit)
        }
        if let weight = config.weight {
            return GymFormat.weightInPounds(weight, storedIn: unit)
        }
        return "-"
    }

    /// Start, resume, and a way to something else.
    ///
    /// ## Three controls and why each is where it is
    ///
    /// `Start <routine>` names the routine on the button, because the whole
    /// point of the card is that the routine is a choice now rather than a
    /// consequence of the date - and a button that says "Start workout" over a
    /// title that says "Ayush B" makes him check which one it means.
    ///
    /// `Different routine` is a secondary control beside it rather than a menu
    /// item: it is the thing that was missing on Sunday, and it should be one
    /// tap from the card. It is hidden while a session is in progress, because
    /// starting another one would silently throw that one away.
    ///
    /// Discard appears only when there is something to discard. "He started
    /// Ayush C, backed out, and now sees Resume workout with no way to abandon
    /// it": a session in progress lives only on this phone (openGym deletes
    /// `active` on every write), so this is the only control anywhere that can
    /// end one - and it asks first, because a discard cannot be undone.
    @ViewBuilder
    private func startButton(_ routine: GymRoutine) -> some View {
        let resuming = store.active != nil
        VStack(spacing: Theme.Space.xs) {
            HStack(spacing: Theme.Space.s) {
                Button {
                    startWorkout(routine.id)
                } label: {
                    HStack(spacing: Theme.Space.xs) {
                        Image(systemName: resuming ? "arrow.clockwise" : "play.fill")
                            .font(.system(size: 13, weight: .semibold))
                        Text(resuming ? "Resume workout" : startLabel(routine))
                            .font(.ataruBody())
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .foregroundStyle(Theme.onAccent)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background {
                        RoundedRectangle(cornerRadius: Theme.Radius.card,
                                         style: .continuous)
                            .fill(Theme.cyan)
                    }
                }
                .buttonStyle(.atPress)
                .disabled(routine.exercises.isEmpty)
                .accessibilityHint(resuming
                    ? "Go back to the session already in progress."
                    : "Log sets for \(routine.name).")

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
                    // ON THE BUTTON, not on the page. A confirmation attached
                    // to the ScrollView has no source to come out of, and what
                    // he saw was a box floating in the middle of the screen
                    // with no relationship to the control he had just pressed.
                    .confirmationDialog("Discard the workout in progress?",
                                        isPresented: $isConfirmingDiscard,
                                        titleVisibility: .visible) {
                        Button("Discard", role: .destructive) { store.discardWorkout() }
                        Button("Keep it", role: .cancel) {}
                    } message: {
                        Text("It only exists on this phone and nothing has been "
                             + "sent to openGym, so it would be gone.")
                    }
                }
            }

            if !resuming {
                Button {
                    isPickingRoutine = true
                } label: {
                    Text("Different routine")
                        .font(.ataruCaption())
                        .foregroundStyle(Theme.cyan)
                        .frame(maxWidth: .infinity)
                        .frame(height: Theme.minHitTarget)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Pick any routine and start it.")
            }
        }
        .padding(.top, Theme.Space.xs)
    }

    /// "Start Ayush B" - and just "Start workout" for a routine with no name
    /// worth putting on a button.
    private func startLabel(_ routine: GymRoutine) -> String {
        routine.name.isEmpty ? "Start workout" : "Start \(routine.name)"
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
                    Text("\(GymFormat.numberInPounds(latest.weight, storedIn: storedUnit)) "
                         + "\(unit) · \(GymFormat.day(latest.day))")
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

    /// Always pounds - what the field is labelled and what it accepts.
    private var unit: String { GymUnits.display }

    /// What the DOCUMENT holds, which the reading above is converted out of.
    private var storedUnit: String { store.documentUnit }

    private var value: Double? {
        Double(draft.replacingOccurrences(of: ",", with: "."))
    }

    private var canSave: Bool {
        guard let value else { return false }
        // A plain sanity bound in POUNDS, not a health judgement: it exists to
        // catch a fat-fingered 1500 before it reaches the log. The old bound
        // was 500, which was a kilogram bound and would have refused any
        // reading over 500 lb on a scale that reads pounds.
        return value > 0 && value < 1200 && !store.isSaving && !store.sync.isReadOnly
    }

    private func save() async {
        guard let value else { return }
        isEditing = false
        if await store.recordBodyweight(pounds: value) { draft = "" }
    }
}
