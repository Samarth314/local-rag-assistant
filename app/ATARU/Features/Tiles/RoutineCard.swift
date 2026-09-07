import SwiftUI

/// The daily routine checklist, at the top of the Health screen.
///
/// ## Why this one card talks to a different backend
///
/// Everything else on `HealthScreen` comes from the read-only health-view
/// service through `TileFetch` - a dashboard renderer with no writer in it.
/// This card is TICKABLE, so it goes through `ATARUService` to the chat
/// server, which owns the vault and can append to the log. Two backends on one
/// screen is unusual and deliberate: the alternative was teaching a read-only
/// dashboard to write, which is exactly the boundary it exists to hold.
///
/// ## Optimistic, with a real rollback
///
/// A tap flips the row immediately and sends the change; the server's answer
/// replaces the whole list. On failure the SAVED SNAPSHOT goes back - not a
/// re-flip of the row, which would be wrong the moment two taps overlap - and
/// the card says the tap did not land. A checklist that silently keeps a tick
/// the vault never recorded is the failure that matters here: he would go to
/// bed believing he had taken something.
///
/// Rows stay tappable during a mutation, unlike the plan's. The plan addresses
/// items by POSITION and has to freeze; every routine item has a stable id, so
/// two taps on two rows are two independent facts and neither can land on the
/// other's row.
@MainActor
final class RoutineViewModel: ObservableObject {
    @Published private(set) var routine: DailyRoutine = .empty
    @Published private(set) var isLoading = false
    @Published private(set) var loadFailed = false
    @Published var errorMessage: String?
    /// The rows with a change in flight, so each can show it individually.
    @Published private(set) var inFlight: Set<String> = []

    private var service: ATARUService?
    private var pushRegistered = false

    func update(service: ATARUService, pushRegistered: Bool) {
        self.service = service
        self.pushRegistered = pushRegistered
    }

    func refresh() async {
        guard let service else { return }
        isLoading = routine.isEmpty
        defer { isLoading = false }
        do {
            routine = try await service.routine()
            loadFailed = false
            errorMessage = nil
            await syncReminders()
        } catch is CancellationError {
            return
        } catch {
            guard !TileFetchError.isCancellation(error) else { return }
            // A refresh that failed over a list already on screen is a lost
            // round trip, not an unreachable server - the same distinction
            // every other tile screen makes. Only a load with nothing to show
            // is reported as a failure.
            loadFailed = routine.isEmpty
            if !routine.isEmpty {
                errorMessage = "Couldn't refresh - this is the last ATARU had."
            }
        }
    }

    func toggle(_ item: RoutineItem) async {
        guard let service, !inFlight.contains(item.id) else { return }
        let snapshot = routine
        let wanted = !item.done
        inFlight.insert(item.id)
        routine = routine.setting(id: item.id, done: wanted)
        errorMessage = nil
        defer { inFlight.remove(item.id) }
        do {
            routine = try await service.routineSetDone(id: item.id, done: wanted)
            await syncReminders()
        } catch is CancellationError {
            routine = snapshot
        } catch {
            routine = snapshot
            errorMessage = "\(item.label) didn't save - tap it again."
        }
    }

    /// Keeps the local fallback reminders in step with the list.
    ///
    /// Called after every load and every toggle, because the point of the
    /// fallback is that finishing the routine at 12:05 stops the 18:00 and
    /// 21:00 nudges. It schedules NOTHING when the server has an APNs token
    /// for this phone - see RoutineReminders for why never both.
    private func syncReminders() async {
        await RoutineReminders.reschedule(for: routine,
                                          pushRegistered: pushRegistered)
    }
}

struct RoutineCard: View {
    @EnvironmentObject private var state: AppState
    @StateObject private var model = RoutineViewModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ATCard {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                header

                if let message = model.errorMessage {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.ataruCaption())
                        .foregroundStyle(Theme.amber)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if model.routine.isEmpty {
                    Text(model.loadFailed
                         ? "Couldn't reach the routine."
                         : (model.isLoading ? "Loading…"
                            : "Nothing on the daily routine yet."))
                        .font(.ataruCaption())
                        .foregroundStyle(Theme.textTertiary)
                } else {
                    ForEach(model.routine.items) { item in
                        row(item)
                    }
                }

                if !model.routine.reminderTimes.isEmpty,
                   !model.routine.allDone {
                    Text("Reminders at "
                         + model.routine.reminderTimes.joined(separator: ", "))
                        .font(.ataruCaption())
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.top, 2)
                }
            }
            .padding(Theme.Space.m)
        }
        .task(id: state.serviceGeneration) {
            model.update(service: state.service,
                         pushRegistered: RemotePushService.shared.isReachableByServer)
            await model.refresh()
        }
        // Back on the network after an outage. Same key every other screen
        // uses - see AppState.onlineGeneration.
        .task(id: state.onlineGeneration) {
            guard state.onlineGeneration > 0 else { return }
            await model.refresh()
        }
        // Back in the foreground. A checklist read at breakfast and looked at
        // again after dinner has to be the evening's list, not the morning's -
        // and the day itself may have rolled over.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task {
                model.update(service: state.service,
                             pushRegistered: RemotePushService.shared.isReachableByServer)
                await model.refresh()
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                SectionHeader(text: "Daily routine")
                if !model.routine.date.isEmpty {
                    Text(model.routine.date)
                        .font(.ataruMono(11))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            Spacer()
            if !model.routine.isEmpty {
                Text("\(model.routine.doneCount) of \(model.routine.items.count) done")
                    .font(.ataruCaption())
                    .foregroundStyle(model.routine.allDone
                                     ? Theme.green : Theme.cyan)
                    .accessibilityLabel(
                        "\(model.routine.doneCount) of \(model.routine.items.count) done today")
            }
        }
    }

    @ViewBuilder
    private func row(_ item: RoutineItem) -> some View {
        Button {
            Task { await model.toggle(item) }
        } label: {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(item.done ? Theme.green : Theme.textTertiary)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.label)
                        .font(.ataruBody())
                        .foregroundStyle(item.done ? Theme.textTertiary
                                                   : Theme.textPrimary)
                        .strikethrough(item.done, color: Theme.textTertiary)
                    Text(subtitle(item))
                        .font(.ataruCaption())
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer()
                if model.inFlight.contains(item.id) {
                    ProgressView()
                        .scaleEffect(0.7)
                }
            }
            .contentShape(Rectangle())
            .padding(.vertical, 3)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.label)
        .accessibilityValue(item.done ? "done" : "not done")
        .accessibilityHint(item.done ? "Mark not done" : "Mark done")
    }

    /// The row's second line: what the item is, and - once it is ticked - when
    /// it was. The time comes from the vault's own log line, never from this
    /// phone's clock, so it is the minute that was actually recorded.
    private func subtitle(_ item: RoutineItem) -> String {
        guard item.done, let at = item.doneAt, !at.isEmpty else {
            return item.detail
        }
        return item.detail.isEmpty ? at : item.detail + " \u{00B7} " + at
    }
}
