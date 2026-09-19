import Charts
import SwiftUI

/// Page three: everything already done, newest first, and the weigh-in series.
struct GymHistoryPage: View {
    @ObservedObject var store: GymStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                GymSyncBadge(sync: store.sync)

                if let state = store.state {
                    bodyweightCard(state)
                    sessions(state)
                } else if case .unavailable(let detail) = store.sync {
                    ATStateView(symbol: "clock.arrow.circlepath",
                                title: "openGym is out of reach",
                                message: detail, tone: Theme.amber)
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

    // MARK: - Sessions

    @ViewBuilder
    private func sessions(_ state: GymState) -> some View {
        let workouts = state.workouts
        if workouts.isEmpty {
            ATStateView(symbol: "clock.arrow.circlepath", title: "No sessions yet",
                        message: "Finished workouts land here, newest first.")
        } else {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                SectionHeader(text: "Sessions")
                // Keyed by position rather than by id: an id is optional in
                // this document and two rows that arrive without one would
                // collapse into a single row.
                ForEach(Array(workouts.enumerated()), id: \.offset) { _, workout in
                    NavigationLink {
                        GymWorkoutDetail(store: store, workout: workout)
                    } label: {
                        row(workout, unit: state.unit)
                    }
                    .buttonStyle(.atPress)
                }
            }
        }
    }

    private func row(_ workout: GymWorkout, unit: String) -> some View {
        ATCard {
            HStack(spacing: Theme.Space.s) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(workout.name.isEmpty ? "Workout" : workout.name)
                        .font(.ataruBody())
                        .foregroundStyle(Theme.textPrimary)
                    Text(subtitle(workout, unit: unit))
                        .font(.ataruCaption())
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer()
                Text(GymFormat.day(workout.day))
                    .font(.ataruMono(11))
                    .foregroundStyle(Theme.textSecondary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .light))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(Theme.Space.m)
        }
        .accessibilityElement(children: .combine)
    }

    private func subtitle(_ workout: GymWorkout, unit: String) -> String {
        var parts = ["\(workout.entries.count) exercises", "\(workout.totalSets) sets"]
        if let minutes = workout.durationMinutes, minutes > 0 {
            parts.append("\(minutes) min")
        }
        if let bodyweight = workout.bodyweight {
            parts.append("\(GymFormat.number(bodyweight)) \(unit)")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Body weight

    @ViewBuilder
    private func bodyweightCard(_ state: GymState) -> some View {
        let entries = state.bodyweight
        if !entries.isEmpty {
            ATCard {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    HStack(alignment: .firstTextBaseline) {
                        SectionHeader(text: "Body weight")
                        Spacer()
                        if let latest = entries.first {
                            Text("\(GymFormat.number(latest.weight)) \(state.unit)")
                                .font(.ataruBody())
                                .foregroundStyle(Theme.textPrimary)
                        }
                    }

                    // Swift Charts, like the Health screen's markers. No axis
                    // labels: this is a shape, and the numbers are in the list
                    // underneath it.
                    if entries.count > 1 {
                        Chart {
                            ForEach(entries.reversed()) { entry in
                                LineMark(x: .value("Day", entry.day),
                                         y: .value("Weight", entry.weight))
                                    .foregroundStyle(Theme.cyan)
                            }
                        }
                        .chartXAxis(.hidden)
                        .chartYScale(domain: .automatic(includesZero: false))
                        .frame(height: 96)
                        .accessibilityLabel("Body weight trend")
                    }

                    ForEach(entries.prefix(10)) { entry in
                        HStack {
                            Text(GymFormat.day(entry.day))
                                .font(.ataruCaption())
                                .foregroundStyle(Theme.textTertiary)
                            Spacer()
                            Text("\(GymFormat.number(entry.weight)) \(state.unit)")
                                .font(.ataruMono(12))
                                .foregroundStyle(Theme.textSecondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(Theme.Space.m)
            }
        }
    }
}

// MARK: - One session

/// A finished session, set by set.
struct GymWorkoutDetail: View {
    @ObservedObject var store: GymStore
    let workout: GymWorkout

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                ATCard {
                    VStack(alignment: .leading, spacing: 2) {
                        SectionHeader(text: GymFormat.day(workout.day))
                        Text(workout.name.isEmpty ? "Workout" : workout.name)
                            .font(.ataruTitle())
                            .foregroundStyle(Theme.textPrimary)
                        Text(summary)
                            .font(.ataruCaption())
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.Space.m)
                }

                ForEach(Array(workout.entries.enumerated()), id: \.offset) { _, entry in
                    ATCard {
                        VStack(alignment: .leading, spacing: Theme.Space.xs) {
                            Text(store.displayName(for: entry.id))
                                .font(.ataruBody())
                                .foregroundStyle(Theme.textPrimary)
                            ForEach(Array(entry.sets.enumerated()), id: \.offset) { index, row in
                                HStack(spacing: Theme.Space.s) {
                                    Text("\(index + 1)")
                                        .font(.ataruMono(11))
                                        .foregroundStyle(Theme.textTertiary)
                                        .frame(width: 16, alignment: .leading)
                                    Text(line(row))
                                        .font(.ataruMono(12))
                                        .foregroundStyle(row.done
                                                         ? Theme.textSecondary
                                                         : Theme.textTertiary)
                                    if row.isWarmup {
                                        ATPill(text: "warmup", tone: Theme.textTertiary)
                                    }
                                    Spacer()
                                    Image(systemName: row.done
                                          ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 13, weight: .light))
                                        .foregroundStyle(row.done
                                                         ? Theme.green : Theme.textTertiary)
                                }
                                .accessibilityElement(children: .combine)
                                .accessibilityValue(row.done ? "done" : "not done")
                            }
                        }
                        .padding(Theme.Space.m)
                    }
                }
            }
            .padding(Theme.Space.screen)
        }
        .ataruBackdrop()
        .navigationTitle(GymFormat.day(workout.day))
        .navigationBarTitleDisplayMode(.inline)
    }

    private var unit: String { store.state?.unit ?? "kg" }

    private var summary: String {
        var parts = ["\(workout.totalSets) sets"]
        if let minutes = workout.durationMinutes, minutes > 0 {
            parts.append("\(minutes) min")
        }
        if let bodyweight = workout.bodyweight {
            parts.append("body weight \(GymFormat.number(bodyweight)) \(unit)")
        }
        return parts.joined(separator: " · ")
    }

    private func line(_ row: GymSetRow) -> String {
        if let seconds = row.seconds { return "\(seconds)s" }
        let reps = row.reps.map { "\($0) reps" } ?? "-"
        guard let weight = row.weight, weight > 0 else { return reps }
        return "\(GymFormat.number(weight)) \(unit) x \(row.reps ?? 0)"
    }
}
