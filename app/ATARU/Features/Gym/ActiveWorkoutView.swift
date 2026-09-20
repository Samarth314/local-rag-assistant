import SwiftUI

/// The session in progress: one card per exercise, one row per set.
///
/// ## What this screen guarantees
///
/// Nothing typed here is lost. Every change goes into the session file on the
/// phone (see `ActiveWorkoutStore`), because openGym's `active` key is deleted
/// by the server on every write - a session in progress exists on this device
/// and nowhere else, so there is no copy to fall back on. A locked phone, a
/// switch to the timer app, or a crash between two sets all come back to the
/// same sets.
///
/// And Finish is the only thing that writes to openGym. Until then this is a
/// scratchpad, which is also why a failed Finish keeps the session rather than
/// clearing it.
struct ActiveWorkoutView: View {
    @ObservedObject var store: GymStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    /// The clock, ticked only while something is resting. The rest itself
    /// lives on the SESSION as an absolute end time (see
    /// `ActiveWorkout.restEndsAt`) - this is just what makes the number on
    /// screen count down.
    @State private var now = Date()
    @State private var isFinishing = false
    /// One flag per TRIGGER, not one per action. A confirmation is anchored to
    /// the control that opened it, and there are two ways to discard a
    /// session - the toolbar menu and the button at the foot of the list - so
    /// there are two flags and two anchors for the one outcome.
    @State private var isConfirmingDiscard = false
    @State private var isConfirmingDiscardFromMenu = false
    /// Which exercise is about to lose its last set, when that set has
    /// already been logged. Nil the rest of the time, which is most of it.
    @State private var isConfirmingSetRemoval: Int?

    private let tick = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    /// Recomputed from the clock on every frame that matters, never
    /// decremented. A phone that spent four minutes in a pocket comes back to
    /// a finished rest rather than to four minutes it never counted.
    private var restSecondsLeft: Int? { store.active?.restRemaining(at: now) }

    var body: some View {
        ZStack(alignment: .bottom) {
            content
            if let secondsLeft = restSecondsLeft {
                restBar(secondsLeft: secondsLeft)
            }
        }
        .ataruBackdrop()
        .navigationTitle(store.active?.routineName ?? "Workout")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Top LEFT, next to the back button that leaves the session
            // running - so the two ways out of this screen sit together and
            // the destructive one is the one behind a menu.
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Button("Discard workout", role: .destructive) {
                        isConfirmingDiscardFromMenu = true
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 16, weight: .light))
                        .foregroundStyle(Theme.textSecondary)
                }
                .accessibilityLabel("Session options")
                .disabled(store.active == nil)
                // On the MENU, not on the menu's button: the button is gone
                // from the hierarchy by the time the menu closes, and a
                // presentation attached to it has nothing left to come out of.
                .discardConfirmation(isPresented: $isConfirmingDiscardFromMenu,
                                     discard: discard)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Finish") { Task { await finish() } }
                    .font(.ataruBody())
                    .foregroundStyle(canFinish ? Theme.cyan : Theme.textTertiary)
                    .disabled(!canFinish)
            }
        }
        .onReceive(tick) { value in
            // Only while something is actually resting: a timer that redraws
            // the page twice a second for no reason is a page that eats
            // battery at the rack.
            guard store.active?.restEndsAt != nil else { return }
            now = value
            store.reconcileRest(at: value)
        }
        // Back from another tile, or from another app. BOTH edges: the rest
        // is recomputed from the clock on the way in, and whatever is on
        // screen is on disk before the app leaves the foreground rather than
        // after it comes back.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                now = Date()
                store.reconcileRest()
            } else {
                store.persistActive()
            }
        }
        .onAppear {
            now = Date()
            store.reconcileRest()
        }
        .onDisappear { store.persistActive() }
        .dismissableNumberPads()
    }

    /// Throw the session away and leave. Both triggers do exactly this, so it
    /// is written once.
    private func discard() {
        store.discardWorkout()
        dismiss()
    }

    @ViewBuilder
    private var content: some View {
        if let workout = store.active {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    if let message = store.errorMessage {
                        ErrorBanner(message: message)
                    }
                    summary(workout)

                    ForEach(Array(workout.entries.enumerated()), id: \.element.id) { index, entry in
                        exerciseCard(index: index, entry: entry)
                    }

                    Button(role: .destructive) {
                        isConfirmingDiscard = true
                    } label: {
                        Text("Discard session")
                            .font(.ataruCaption())
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(Theme.red)
                    .padding(.top, Theme.Space.s)
                    // Clear of the rest bar when it is up.
                    .padding(.bottom, Theme.Space.xxl)
                    .discardConfirmation(isPresented: $isConfirmingDiscard,
                                         discard: discard)
                }
                .padding(Theme.Space.screen)
            }
        } else {
            ATStateView(symbol: "dumbbell", title: "No session in progress",
                        message: "Start one from the Gym screen.")
        }
    }

    private var unit: String { store.state?.unit ?? "kg" }

    private var canFinish: Bool {
        (store.active?.hasAnythingLogged ?? false) && !isFinishing && !store.isSaving
    }

    // MARK: - Header

    private func summary(_ workout: ActiveWorkout) -> some View {
        ATCard {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    SectionHeader(text: GymFormat.day(workout.day))
                    Text("\(workout.doneSetCount) of \(workout.totalSetCount) sets done")
                        .font(.ataruBody())
                        .foregroundStyle(Theme.textPrimary)
                }
                Spacer()
                Text(elapsed(workout))
                    .font(.ataruMono(13))
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(Theme.Space.m)
        }
        .accessibilityElement(children: .combine)
    }

    private func elapsed(_ workout: ActiveWorkout) -> String {
        let minutes = max(0, (GymClock.milliseconds() - workout.startedAt) / 60_000)
        return minutes < 60
            ? "\(minutes) min"
            : "\(minutes / 60)h \(minutes % 60)m"
    }

    // MARK: - One exercise

    private func exerciseCard(index: Int, entry: ActiveWorkout.Entry) -> some View {
        ATCard {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                HStack(spacing: Theme.Space.s) {
                    // The demo, and the way to a bigger one. A thumbnail
                    // rather than the animation: fourteen exercises animating
                    // at once is fourteen display links running at the rack.
                    NavigationLink {
                        GymExerciseDetail(
                            name: store.displayName(for: entry.exerciseID),
                            entry: store.libraryEntry(for: entry.exerciseID),
                            gifURL: store.gifURL(forExercise: entry.exerciseID))
                    } label: {
                        GymExerciseThumbnail(
                            url: store.gifURL(forExercise: entry.exerciseID))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Show \(entry.name)")

                    Text(entry.name)
                        .font(.ataruBody())
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Text("\(entry.doneCount)/\(entry.sets.count)")
                        .font(.ataruMono(11))
                        .foregroundStyle(entry.doneCount == entry.sets.count
                                         ? Theme.green : Theme.textTertiary)
                }

                ForEach(Array(entry.sets.enumerated()), id: \.element.id) { row, set in
                    ActiveSetRow(
                        number: row + 1,
                        set: set,
                        unit: unit,
                        onEdit: { weight, reps in
                            // Typing is not an event worth a disk write per
                            // character; the moments that matter persist
                            // below.
                            store.updateActive(persist: false) { workout in
                                guard workout.entries.indices.contains(index),
                                      workout.entries[index].sets.indices.contains(row)
                                else { return }
                                workout.entries[index].sets[row].weight = weight
                                workout.entries[index].sets[row].reps = reps
                            }
                        },
                        onToggle: { toggle(entry: index, set: row) })
                }

                HStack(spacing: Theme.Space.s) {
                    Button {
                        addSet(to: index)
                    } label: {
                        Label("Add set", systemImage: "plus")
                            .font(.ataruCaption())
                    }
                    Button {
                        // A spare set he never got to goes without asking -
                        // that is tidying, not deleting. A set he has already
                        // ticked is the only record of it that exists, so
                        // that one asks.
                        if entry.sets.last?.done == true {
                            isConfirmingSetRemoval = index
                        } else {
                            removeSet(from: index)
                        }
                    } label: {
                        Label("Remove set", systemImage: "minus")
                            .font(.ataruCaption())
                    }
                    .disabled(entry.sets.count <= 1)
                    .confirmationDialog(
                        "Remove the last set?",
                        isPresented: Binding(
                            get: { isConfirmingSetRemoval == index },
                            set: { if !$0 { isConfirmingSetRemoval = nil } }),
                        titleVisibility: .visible) {
                        Button("Remove", role: .destructive) {
                            removeSet(from: index)
                            isConfirmingSetRemoval = nil
                        }
                        Button("Keep it", role: .cancel) {
                            isConfirmingSetRemoval = nil
                        }
                    } message: {
                        Text("It is logged, and this phone is the only place "
                             + "it exists until you finish.")
                    }
                    Spacer()
                }
                .buttonStyle(.bordered)
                .tint(Theme.cyan)
                .padding(.top, 2)
            }
            .padding(Theme.Space.m)
        }
    }

    // MARK: - Editing

    private func toggle(entry: Int, set: Int) {
        var startedResting = false
        store.updateActive { workout in
            guard workout.entries.indices.contains(entry),
                  workout.entries[entry].sets.indices.contains(set) else { return }
            let wanted = !workout.entries[entry].sets[set].done
            workout.entries[entry].sets[set].done = wanted
            startedResting = wanted
        }
        // The rest starts when a set is finished, which is the only moment the
        // phone can know it without being told. Un-ticking a set is the one
        // way to say it did not happen, so the rest goes with it.
        if startedResting {
            now = Date()
            store.startRest()
        } else {
            store.stopRest()
        }
    }

    private func addSet(to index: Int) {
        store.updateActive { workout in
            guard workout.entries.indices.contains(index) else { return }
            // A new set copies the last one, which is what the next set almost
            // always is.
            let last = workout.entries[index].sets.last
            workout.entries[index].sets.append(
                ActiveWorkout.SetEntry(weight: last?.weight ?? 0,
                                       reps: last?.reps ?? 10, done: false))
        }
    }

    private func removeSet(from index: Int) {
        store.updateActive { workout in
            guard workout.entries.indices.contains(index),
                  workout.entries[index].sets.count > 1 else { return }
            workout.entries[index].sets.removeLast()
        }
    }

    private func finish() async {
        isFinishing = true
        defer { isFinishing = false }
        if await store.finishWorkout() { dismiss() }
    }

    // MARK: - Rest

    /// A bar rather than a sheet: it has to be dismissable with the same thumb
    /// that is about to pick the bar back up, and it must never cover the set
    /// that is being logged.
    private func restBar(secondsLeft: Int) -> some View {
        Button {
            store.stopRest()
        } label: {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: "timer")
                    .font(.system(size: 15, weight: .light))
                Text("Rest \(secondsLeft)s")
                    .font(.ataruBody())
                Spacer()
                Text("tap to skip")
                    .font(.ataruCaption())
                    .foregroundStyle(Theme.textTertiary)
            }
            .foregroundStyle(Theme.cyan)
            .padding(.horizontal, Theme.Space.m)
            .frame(height: 48)
            .frame(maxWidth: .infinity)
            .background {
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .fill(Theme.surfaceElevated)
                    .overlay {
                        RoundedRectangle(cornerRadius: Theme.Radius.card,
                                         style: .continuous)
                            .strokeBorder(Theme.cyanSubdued, lineWidth: 1)
                    }
            }
            .padding(.horizontal, Theme.Space.screen)
            .padding(.bottom, Theme.Space.s)
        }
        .buttonStyle(.plain)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .accessibilityLabel("Resting, \(secondsLeft) seconds left")
        .accessibilityHint("Skip the rest timer")
    }
}

// MARK: - One set

/// A single set: what is on the bar, how many, and whether it happened.
///
/// The two fields keep their own text while they are being typed. Binding them
/// straight at the model would reformat "8" into "8" the moment a decimal
/// point is typed and fight the keyboard all the way to 82.5.
private struct ActiveSetRow: View {
    let number: Int
    let set: ActiveWorkout.SetEntry
    let unit: String
    let onEdit: (Double, Int) -> Void
    let onToggle: () -> Void

    @State private var weightText = ""
    @State private var repsText = ""

    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            Text("\(number)")
                .font(.ataruMono(11))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 16, alignment: .leading)

            field(text: $weightText, width: 66, label: "Weight in \(unit)")
                .onChange(of: weightText) { _, _ in commit() }
            Text(unit)
                .font(.ataruCaption())
                .foregroundStyle(Theme.textTertiary)

            field(text: $repsText, width: 52, label: "Reps")
                .onChange(of: repsText) { _, _ in commit() }
            Text("reps")
                .font(.ataruCaption())
                .foregroundStyle(Theme.textTertiary)

            Spacer(minLength: Theme.Space.xs)

            Button(action: onToggle) {
                Image(systemName: set.done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(set.done ? Theme.green : Theme.textTertiary)
                    .hitTarget()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Set \(number)")
            .accessibilityValue(set.done ? "done" : "not done")
            .accessibilityHint(set.done ? "Mark not done" : "Mark done and start the rest timer")
        }
        .padding(.vertical, 1)
        .task(id: set.id) {
            weightText = set.weight == 0 ? "" : GymFormat.number(set.weight)
            repsText = String(set.reps)
        }
    }

    private func field(text: Binding<String>, width: CGFloat,
                       label: String) -> some View {
        TextField("0", text: text)
            .keyboardType(.decimalPad)
            .multilineTextAlignment(.trailing)
            .font(.ataruMono(13))
            .foregroundStyle(Theme.textPrimary)
            .frame(width: width, height: 34)
            .padding(.horizontal, Theme.Space.xxs)
            .background {
                RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                    .fill(Theme.surfaceElevated)
            }
            .accessibilityLabel(label)
    }

    private func commit() {
        let weight = Double(weightText.replacingOccurrences(of: ",", with: ".")) ?? 0
        let reps = Int(repsText) ?? 0
        onEdit(weight, reps)
    }
}

// MARK: - The one confirmation, at two anchors

private extension View {
    /// "Discard this session?", attached to whichever control asked.
    ///
    /// Written once because the copy has to be the same wherever it comes
    /// from: two confirmations for one action that word it differently read
    /// as two different actions.
    func discardConfirmation(isPresented: Binding<Bool>,
                             discard: @escaping () -> Void) -> some View {
        confirmationDialog("Discard this session?", isPresented: isPresented,
                           titleVisibility: .visible) {
            Button("Discard", role: .destructive, action: discard)
            Button("Keep logging", role: .cancel) {}
        } message: {
            Text("Nothing has been sent to openGym yet, so this would be gone.")
        }
    }
}
