import SwiftUI

// MARK: - Pick a routine and start it

/// Every routine, when each was last done, and one tap to begin.
///
/// ## Why this exists at all
///
/// The Today card names ONE routine - whatever is next in the loop - and that
/// is right almost every day. This is the other days: a Sunday he decides to
/// train anyway, a week where he wants to repeat a session, a day he skips
/// legs. Until this there was no control anywhere in the app that named a
/// routine other than the calendar's, which is exactly what he ran into:
/// "the app had no way of me selecting a routine and doing it today".
///
/// No confirmation, by instruction and because a confirmation would be wrong:
/// starting a session writes nothing anywhere (openGym's `active` is
/// device-local and this phone is the only copy), and a session started by
/// mistake is discarded from the card in two taps.
///
/// "Last done" is the one fact that makes the list a decision rather than a
/// menu, and "never" is said plainly - a blank cell in that column reads as
/// missing data on a list whose whole job is to show which routine is overdue.
struct GymRoutinePicker: View {
    @ObservedObject var store: GymStore
    let onPick: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    let routines = store.state?.routines ?? []
                    if routines.isEmpty {
                        ATStateView(symbol: "dumbbell", title: "No routines yet",
                                    message: "Routines created in openGym show up here.")
                    } else {
                        ForEach(routines) { routine in
                            Button {
                                onPick(routine.id)
                            } label: {
                                row(routine)
                            }
                            .buttonStyle(.atPress)
                            // A routine with nothing in it has no session to
                            // start. Shown rather than hidden, so the list is
                            // the profile's routines and not a filtered view
                            // of them.
                            .disabled(routine.exercises.isEmpty)
                        }
                    }
                }
                .padding(Theme.Space.screen)
            }
            .ataruBackdrop()
            .navigationTitle("Start a routine")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .font(.ataruBody())
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func row(_ routine: GymRoutine) -> some View {
        ATCard {
            HStack(spacing: Theme.Space.s) {
                ZStack {
                    Circle()
                        .fill(Theme.accentSoft)
                        .frame(width: 36, height: 36)
                    Text(routine.shortLabel)
                        .font(.ataruBody())
                        .foregroundStyle(Theme.cyan)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(routine.name.isEmpty ? "Routine \(routine.id)" : routine.name)
                        .font(.ataruBody())
                        .foregroundStyle(Theme.textPrimary)
                    Text(subtitle(routine))
                        .font(.ataruCaption())
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer()
                Image(systemName: "play.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(routine.exercises.isEmpty
                                     ? Theme.textTertiary : Theme.cyan)
            }
            .padding(Theme.Space.m)
        }
        .accessibilityElement(children: .combine)
    }

    private func subtitle(_ routine: GymRoutine) -> String {
        let count = routine.exercises.count
        let exercises = "\(count) exercise\(count == 1 ? "" : "s")"
        let last = GymFormat.since(store.state?.lastDay(forRoutine: routine.id))
        return "\(exercises) · \(last)"
    }
}

// MARK: - Log a workout that already happened

/// A workout Arya did and is typing in afterwards.
///
/// ## What this is for
///
/// "I ended up doing Ayush A yesterday." With no way to start a routine on a
/// rest day, the session happened and the log did not - and because the
/// rotation now follows what was completed rather than the calendar, a missing
/// session is not just a missing row, it puts every following day's next-up
/// one routine out of step. So there has to be a way to put it back.
///
/// ## Why the weights are one field per exercise
///
/// A live session has a field per set, because he is standing there and the
/// third set is genuinely a different number from the first. Recalling a
/// session afterwards is not that: what a person remembers is "I did the squat
/// at 185", and a grid of empty per-set boxes to be filled with the same
/// number five times is a form nobody finishes. One field per exercise fills
/// every set of it, blank stays blank, and the sets and reps come from the
/// routine's own targets - which is what "prefilled from the routine" means.
///
/// Blank is a real answer and the commonest one. Zero is openGym's own
/// spelling for a set with no external load, so a workout logged with no
/// numbers at all invents nothing - it records that the session happened, on
/// the day it happened, with the sets the routine plans.
///
/// ## What it writes
///
/// The same `finishedWorkout` shape a session logged at the rack writes, plus
/// `loggedLater: true`. Identical code path on purpose - see
/// `GymStore.logPastWorkout`.
struct GymPastWorkoutForm: View {
    @ObservedObject var store: GymStore

    @Environment(\.dismiss) private var dismiss

    @State private var routineID = ""
    @State private var day = Self.yesterday
    /// Text, not numbers: the field keeps what was typed until it is read, so
    /// a decimal point mid-type does not fight the keyboard.
    @State private var typed: [String: String] = [:]
    @State private var isSaving = false
    @State private var hasLoaded = false

    /// The default date, because the overwhelmingly likely case is the one
    /// that prompted this whole screen: a session yesterday that never got
    /// logged.
    private static var yesterday: Date {
        Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    if store.sync.isReadOnly {
                        InlineNote(text: "Read-only while openGym is out of reach - "
                                   + "this can't be saved yet.")
                    }
                    if let message = store.errorMessage {
                        ErrorBanner(message: message)
                    }
                    whatAndWhen
                    if let routine = store.state?.routine(id: routineID) {
                        sets(routine)
                    }
                }
                .padding(Theme.Space.screen)
            }
            .ataruBackdrop()
            .dismissableNumberPads()
            .navigationTitle("Log a past workout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .font(.ataruBody())
                        .foregroundStyle(Theme.textSecondary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { Task { await save() } }
                        .font(.ataruBody())
                        .foregroundStyle(canSave ? Theme.cyan : Theme.textTertiary)
                        .disabled(!canSave)
                }
            }
            .task {
                guard !hasLoaded else { return }
                hasLoaded = true
                // Next up, which on the day this was written is also the
                // routine he actually did. Deliberately NOT re-derived when
                // the date changes: a control that silently changes its own
                // value while you are using another one is the more surprising
                // of the two behaviours.
                routineID = store.nextRoutineID ?? store.state?.routines.first?.id ?? ""
            }
        }
        .presentationDetents([.large])
    }

    // MARK: Which routine, and when

    private var whatAndWhen: some View {
        ATCard {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                HStack {
                    Text("Routine")
                        .font(.ataruCaption())
                        .foregroundStyle(Theme.textTertiary)
                    Spacer()
                    Picker("Routine", selection: $routineID) {
                        ForEach(store.state?.routines ?? []) { routine in
                            Text(routine.name.isEmpty ? routine.id : routine.name)
                                .tag(routine.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(Theme.cyan)
                }

                Divider().overlay(Theme.border)

                // No future dates. A workout that has not happened is not a
                // past workout, and a session dated tomorrow would take over
                // the rotation from every real one.
                DatePicker("Day", selection: $day, in: ...Date(),
                           displayedComponents: .date)
                    .datePickerStyle(.compact)
                    .font(.ataruCaption())
                    .foregroundStyle(Theme.textTertiary)
                    .tint(Theme.cyan)

                Text("Saved as a finished workout on that day, with the "
                     + "routine's sets, and marked as logged later.")
                    .font(.ataruCaption())
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(Theme.Space.m)
        }
    }

    // MARK: The sets

    @ViewBuilder
    private func sets(_ routine: GymRoutine) -> some View {
        ATCard {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                SectionHeader(text: "Sets")
                if routine.exercises.isEmpty {
                    Text("This routine has no exercises yet.")
                        .font(.ataruCaption())
                        .foregroundStyle(Theme.textTertiary)
                }
                ForEach(Array(routine.exercises.enumerated()), id: \.offset) { index, config in
                    row(config)
                    if index < routine.exercises.count - 1 {
                        Divider().overlay(Theme.border)
                    }
                }
            }
            .padding(Theme.Space.m)
        }
    }

    /// One exercise: what the routine plans, and one weight for all of it.
    ///
    /// The field is keyed by exercise id, so a routine that lists the same
    /// exercise twice shares one number between both entries. That is the same
    /// assumption `GymStore.logPastWorkout` makes, and it is the right one for
    /// a form about what somebody remembers.
    private func row(_ config: GymExerciseConfig) -> some View {
        HStack(spacing: Theme.Space.s) {
            VStack(alignment: .leading, spacing: 1) {
                Text(store.displayName(for: config.id))
                    .font(.ataruBody())
                    .foregroundStyle(Theme.textPrimary)
                Text(GymFormat.target(sets: config.sets, reps: config.reps))
                    .font(.ataruCaption())
                    .foregroundStyle(Theme.textTertiary)
            }
            Spacer(minLength: Theme.Space.s)
            TextField("-", text: Binding(
                get: { typed[config.id] ?? "" },
                set: { typed[config.id] = $0 }))
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .font(.ataruMono(13))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 70, height: 34)
                .padding(.horizontal, Theme.Space.xxs)
                .background {
                    RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                        .fill(Theme.surfaceElevated)
                }
                .accessibilityLabel("\(store.displayName(for: config.id)), weight in "
                                    + GymUnits.display)
            Text(GymUnits.display)
                .font(.ataruCaption())
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(.vertical, 2)
    }

    // MARK: Saving

    private var canSave: Bool {
        guard !routineID.isEmpty, !isSaving, !store.isSaving,
              !store.sync.isReadOnly else { return false }
        return store.state?.routine(id: routineID)?.exercises.isEmpty == false
    }

    /// Pounds, keyed by exercise id. A field that is blank, or that holds
    /// something that is not a number, contributes nothing - it does not
    /// contribute a zero and it does not block the save.
    private var weights: [String: Double] {
        var out: [String: Double] = [:]
        for (id, text) in typed {
            let cleaned = text.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: ",", with: ".")
            guard let value = Double(cleaned), value > 0 else { continue }
            out[id] = value
        }
        return out
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        let stored = await store.logPastWorkout(routineID: routineID,
                                                on: GymClock.day(day),
                                                weights: weights)
        // Only on success. A failed write keeps the form open with whatever
        // was typed in it, because nothing else in this app is holding those
        // numbers.
        if stored { dismiss() }
    }
}
