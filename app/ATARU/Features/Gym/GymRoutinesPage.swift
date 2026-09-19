import SwiftUI

/// Page two: the routines, and what is in them.
struct GymRoutinesPage: View {
    @ObservedObject var store: GymStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                GymSyncBadge(sync: store.sync)

                if let state = store.state, !state.routines.isEmpty {
                    ForEach(state.routines) { routine in
                        NavigationLink {
                            GymRoutineDetail(store: store, routineID: routine.id)
                        } label: {
                            card(routine)
                        }
                        .buttonStyle(.atPress)
                    }
                } else if case .unavailable(let detail) = store.sync {
                    ATStateView(symbol: "dumbbell", title: "openGym is out of reach",
                                message: detail, tone: Theme.amber)
                } else if store.state != nil {
                    ATStateView(symbol: "dumbbell", title: "No routines yet",
                                message: "Routines created in openGym show up here.")
                } else {
                    ProgressView()
                        .tint(Theme.cyan)
                        .frame(maxWidth: .infinity)
                        .padding(.top, Theme.Space.xl)
                }
            }
            .padding(Theme.Space.screen)
        }
        .refreshable { await store.refresh() }
    }

    private func card(_ routine: GymRoutine) -> some View {
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
                    Text(routine.name)
                        .font(.ataruBody())
                        .foregroundStyle(Theme.textPrimary)
                    Text(subtitle(routine))
                        .font(.ataruCaption())
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .light))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(Theme.Space.m)
        }
        .accessibilityElement(children: .combine)
    }

    private func subtitle(_ routine: GymRoutine) -> String {
        let count = routine.exercises.count
        let sets = routine.exercises.reduce(0) { $0 + $1.sets }
        let exercises = "\(count) exercise\(count == 1 ? "" : "s")"
        guard let last = store.state?.lastWorkout(forRoutine: routine.id) else {
            return "\(exercises) · \(sets) sets"
        }
        return "\(exercises) · \(sets) sets · last \(GymFormat.day(last.day))"
    }
}

// MARK: - Detail

/// One routine, and the only place in the app that changes what it contains.
///
/// ## Edited locally, saved once
///
/// Every field here edits a DRAFT, and Save writes the whole document once.
/// The alternative - a PUT per stepper tap - would be a revision bump per
/// keystroke against a document the web app is also polling, which is how two
/// clients end up merging all afternoon.
struct GymRoutineDetail: View {
    @ObservedObject var store: GymStore
    let routineID: String

    @State private var draft: [GymExerciseConfig] = []
    @State private var expanded: Int?
    @State private var newExercise = ""
    @State private var isAdding = false
    @State private var removing: Int?
    @State private var loadedFor: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                if store.sync.isReadOnly {
                    InlineNote(text: "Read-only while openGym is out of reach - "
                               + "changes can't be saved.")
                }
                if let message = store.errorMessage {
                    ErrorBanner(message: message)
                }

                ATCard {
                    VStack(alignment: .leading, spacing: Theme.Space.xs) {
                        SectionHeader(text: "Exercises")
                        if draft.isEmpty {
                            Text("Nothing in this routine yet.")
                                .font(.ataruCaption())
                                .foregroundStyle(Theme.textTertiary)
                        }
                        ForEach(Array(draft.enumerated()), id: \.offset) { index, config in
                            row(index: index, config: config)
                            if index < draft.count - 1 {
                                Divider().overlay(Theme.border)
                            }
                        }
                    }
                    .padding(Theme.Space.m)
                }

                addCard
            }
            .padding(Theme.Space.screen)
        }
        .ataruBackdrop()
        .navigationTitle(store.state?.routine(id: routineID)?.name ?? "Routine")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Save") { Task { await save() } }
                    .font(.ataruBody())
                    .foregroundStyle(canSave ? Theme.cyan : Theme.textTertiary)
                    .disabled(!canSave)
            }
        }
        .task(id: store.revision) {
            // Reloaded when the document moves underneath, but NEVER on top of
            // an edit in progress: adopting the server's copy mid-edit is how
            // a stepper tap silently reverts.
            guard loadedFor == nil || !isDirty else { return }
            draft = store.state?.routine(id: routineID)?.exercises ?? []
            loadedFor = key
        }
        .confirmationDialog("Remove this exercise from the routine?",
                            isPresented: Binding(get: { removing != nil },
                                                 set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                if let index = removing, draft.indices.contains(index) {
                    draft.remove(at: index)
                    expanded = nil
                }
                removing = nil
            }
            Button("Keep it", role: .cancel) { removing = nil }
        }
    }

    private var key: String { "\(routineID)#\(store.revision)" }

    private var unit: String { store.state?.unit ?? "kg" }

    private var isDirty: Bool {
        draft != (store.state?.routine(id: routineID)?.exercises ?? [])
    }

    private var canSave: Bool { isDirty && !store.isSaving && !store.sync.isReadOnly }

    // MARK: Rows

    @ViewBuilder
    private func row(index: Int, config: GymExerciseConfig) -> some View {
        let isOpen = expanded == index
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Button {
                withAnimation(Theme.quick) { expanded = isOpen ? nil : index }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(store.names.name(for: config.id))
                            .font(.ataruBody())
                            .foregroundStyle(Theme.textPrimary)
                        Text(summary(config))
                            .font(.ataruCaption())
                            .foregroundStyle(Theme.textTertiary)
                    }
                    Spacer(minLength: Theme.Space.s)
                    Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12, weight: .light))
                        .foregroundStyle(Theme.textTertiary)
                }
                .contentShape(Rectangle())
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(store.names.name(for: config.id))
            .accessibilityValue(summary(config))
            .accessibilityHint(isOpen ? "Collapse" : "Edit sets, reps and weight")

            if isOpen { editor(index: index) }
        }
    }

    private func summary(_ config: GymExerciseConfig) -> String {
        switch config.mode {
        case "time":
            let seconds = config.seconds.map { "\($0)s" } ?? "-"
            return "\(config.sets) x \(seconds)"
        case "cardio":
            let minutes = config.minutes.map { "\(GymFormat.number($0)) min" } ?? "-"
            let speed = config.speed.map { " at \(GymFormat.number($0))" } ?? ""
            return minutes + speed
        default:
            let target = GymFormat.target(sets: config.sets, reps: config.reps)
            return "\(target) · \(GymFormat.weight(config.weight, unit: unit))"
        }
    }

    @ViewBuilder
    private func editor(index: Int) -> some View {
        let config = draft[index]
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            // Only the reps mode is editable here. A time or cardio config
            // carries `sec` or `min`/`speed`, and inventing an editor for
            // fields this screen has never been shown a real example of is how
            // a client writes a document the web app then discards.
            if config.mode == "reps" {
                stepper("Sets", value: config.sets, range: 1...12) { new in
                    draft[index].setSets(new)
                }
                stepper("Reps", value: config.reps ?? 0, range: 0...50) { new in
                    draft[index].setReps(new)
                }
                weightRow(index: index)
            } else {
                Text("Edit \(config.mode) exercises in openGym - this screen "
                     + "only changes sets, reps and weight.")
                    .font(.ataruCaption())
                    .foregroundStyle(Theme.textTertiary)
            }

            HStack(spacing: Theme.Space.s) {
                Button {
                    move(index, by: -1)
                } label: {
                    Label("Up", systemImage: "arrow.up")
                        .font(.ataruCaption())
                }
                .disabled(index == 0)
                Button {
                    move(index, by: 1)
                } label: {
                    Label("Down", systemImage: "arrow.down")
                        .font(.ataruCaption())
                }
                .disabled(index >= draft.count - 1)
                Spacer()
                Button(role: .destructive) {
                    removing = index
                } label: {
                    Label("Remove", systemImage: "minus.circle")
                        .font(.ataruCaption())
                }
            }
            .tint(Theme.cyan)
            .buttonStyle(.bordered)
            .padding(.top, 2)
        }
        .padding(.bottom, Theme.Space.xs)
    }

    private func stepper(_ label: String, value: Int, range: ClosedRange<Int>,
                         set: @escaping (Int) -> Void) -> some View {
        Stepper(value: Binding(get: { value }, set: set), in: range) {
            HStack {
                Text(label)
                    .font(.ataruCaption())
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
                Text("\(value)")
                    .font(.ataruMono(13))
                    .foregroundStyle(Theme.textPrimary)
            }
        }
        .tint(Theme.cyan)
    }

    private func weightRow(index: Int) -> some View {
        HStack(spacing: Theme.Space.s) {
            Text("Weight")
                .font(.ataruCaption())
                .foregroundStyle(Theme.textTertiary)
            Spacer()
            TextField("0", text: Binding(
                get: { draft[index].weight.map(GymFormat.number) ?? "" },
                set: { text in
                    let cleaned = text.replacingOccurrences(of: ",", with: ".")
                    draft[index].setWeight(cleaned.isEmpty ? nil : Double(cleaned))
                }))
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .font(.ataruMono(13))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 70, height: 34)
                .padding(.horizontal, Theme.Space.xs)
                .background {
                    RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                        .fill(Theme.surfaceElevated)
                }
                .accessibilityLabel("Weight in \(unit)")
            Text(unit)
                .font(.ataruCaption())
                .foregroundStyle(Theme.textTertiary)
        }
    }

    private func move(_ index: Int, by offset: Int) {
        let target = index + offset
        guard draft.indices.contains(index), draft.indices.contains(target) else { return }
        withAnimation(Theme.quick) {
            draft.swapAt(index, target)
            expanded = target
        }
    }

    // MARK: Adding

    /// Adding an exercise, and an honest note about what it can be.
    ///
    /// openGym's 1324 built-in exercises live in the container's own dataset
    /// and the ATARU server publishes no endpoint for them, so this app cannot
    /// offer that picker without inventing one. What it CAN do is what openGym
    /// itself does for anything not in the catalogue: add a custom exercise by
    /// name, which the web app treats identically. The note says so rather
    /// than leaving a search field that would return nothing.
    private var addCard: some View {
        ATCard {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                SectionHeader(text: "Add an exercise")
                HStack(spacing: Theme.Space.s) {
                    TextField("Name", text: $newExercise)
                        .font(.ataruBody())
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.horizontal, Theme.Space.s)
                        .frame(height: Theme.minHitTarget)
                        .background {
                            RoundedRectangle(cornerRadius: Theme.Radius.small,
                                             style: .continuous)
                                .fill(Theme.surfaceElevated)
                        }
                    Button("Add") { Task { await add() } }
                        .font(.ataruBody())
                        .foregroundStyle(canAdd ? Theme.cyan : Theme.textTertiary)
                        .frame(minHeight: Theme.minHitTarget)
                        .disabled(!canAdd)
                }
                Text("Added as a custom exercise, at 3 x 10. openGym's built-in "
                     + "library isn't reachable from the phone yet - search it "
                     + "in the browser to add one of those.")
                    .font(.ataruCaption())
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(Theme.Space.m)
        }
    }

    private var canAdd: Bool {
        !newExercise.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isAdding && !store.sync.isReadOnly
    }

    private func add() async {
        guard !isDirty else {
            store.errorMessage = "Save the changes above first."
            return
        }
        isAdding = true
        defer { isAdding = false }
        if await store.addExercise(named: newExercise, to: routineID) {
            newExercise = ""
            draft = store.state?.routine(id: routineID)?.exercises ?? []
            loadedFor = key
        }
    }

    private func save() async {
        guard var routine = store.state?.routine(id: routineID) else { return }
        routine.setExercises(draft)
        if await store.save(routine: routine) {
            draft = store.state?.routine(id: routineID)?.exercises ?? []
            loadedFor = key
            expanded = nil
        }
    }
}
