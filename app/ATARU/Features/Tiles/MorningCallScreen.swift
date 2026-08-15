import SwiftUI

/// When the morning call rings tomorrow.
///
/// The call is scheduled server-side and always has been - this is only the
/// dial, so the phone stops being the one device that can hear the call but
/// not change it.
///
/// ## Times are strings, not Dates
///
/// The server schedules against a wall clock in its own timezone. A `Date`
/// carries an instant, and an instant round-tripped through this device's
/// timezone is how 07:00 becomes 06:00 after a flight. So the wire format is
/// "HH:MM" end to end; the picker converts once for editing, reads back only
/// the hour and minute the user actually dialled, and the absolute date behind
/// the picker is never sent anywhere.
///
/// ## Why "not available yet" is a first-class state
///
/// The endpoint may not be deployed on his server. A missing route returns 404
/// and `ATARUService`'s default implementation throws the same thing, so both
/// arrive here as `APIError.notFound` and are reported as plainly as possible.
/// The one outcome this screen must never produce is a save that appears to
/// work and is not stored - that is a phone that does not ring in the morning
/// with nothing anywhere saying why.
struct MorningCallScreen: View {
    @EnvironmentObject private var state: AppState

    private enum Phase: Equatable {
        case loading
        case ready
        case unavailable
        case failed(String)
    }

    @State private var phase: Phase = .loading
    @State private var schedule: MorningSchedule?
    /// Hour and minute only. See the note above about instants.
    @State private var picked = Date()
    @State private var isSaving = false
    @State private var confirmation: String?
    @State private var saveError: String?

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Space.m) {
                switch phase {
                case .loading:
                    // First load with nothing to show: a minimal centred
                    // indicator, no card and no words. See ScreenState for the
                    // one rule this follows.
                    ProgressView()
                        .tint(Theme.cyan)
                        .frame(maxWidth: .infinity)
                        .padding(.top, Theme.Space.xl)

                case .unavailable:
                    unavailableCard

                case .failed(let message):
                    ErrorBanner(message: message)
                    retryButton

                case .ready:
                    currentCard
                    pickerCard
                    if let confirmation {
                        confirmationCard(confirmation)
                    }
                    if let saveError {
                        ErrorBanner(message: saveError)
                    }
                }
            }
            .padding(Theme.Space.screen)
        }
        .ataruBackdrop()
        .navigationTitle("Morning call")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
    }

    // MARK: - Cards

    private var unavailableCard: some View {
        ATCard {
            VStack(spacing: Theme.Space.s) {
                Image(systemName: "clock.badge.questionmark")
                    .font(.system(size: 34, weight: .ultraLight))
                    .foregroundStyle(Theme.textTertiary)
                Text("Not available yet")
                    .font(.ataruLabel())
                    .foregroundStyle(Theme.textPrimary)
                Text("This server has no morning schedule endpoint. The call still rings on whatever it is already set to - this page just cannot change it.")
                    .font(.ataruCaption())
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(Theme.Space.l)
            .frame(maxWidth: .infinity)
        }
    }

    private var currentCard: some View {
        ATCard {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                SectionHeader(text: "Currently set")
                Text(MorningSchedule.display(schedule?.callTime ?? "--:--"))
                    .font(.ataruTitle())
                    .foregroundStyle(Theme.cyan)
                Text(scopeLine)
                    .font(.ataruCaption())
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(Theme.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var pickerCard: some View {
        ATCard {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                SectionHeader(text: "Tomorrow")
                DatePicker("First call", selection: $picked,
                           displayedComponents: .hourAndMinute)
                    .datePickerStyle(.wheel)
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                    .colorScheme(.dark)

                Button {
                    Task { await save() }
                } label: {
                    // Constant label, constant size. A spinner appearing
                    // inside the button and the word changing to "Setting"
                    // both resized it mid-tap; dimming says the same thing and
                    // moves nothing. The confirmation card is the real answer.
                    Text("Set for tomorrow")
                        .font(.ataruLabel())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Theme.Space.s)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.cyan)
                .opacity(isSaving ? 0.6 : 1)
                .animation(.easeOut(duration: 0.18), value: isSaving)
                .disabled(isSaving)
            }
            .padding(Theme.Space.m)
        }
    }

    private func confirmationCard(_ text: String) -> some View {
        ATCard {
            Label(text, systemImage: "checkmark.circle")
                .font(.ataruLabel())
                .foregroundStyle(Theme.green)
                .padding(Theme.Space.m)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var retryButton: some View {
        Button("Try again") { Task { await load() } }
            .font(.ataruLabel())
            .tint(Theme.cyan)
    }

    /// Whether the time on screen is a one-off for a particular day or just
    /// the standing default, said in words rather than left to be inferred
    /// from a date field.
    private var scopeLine: String {
        guard let schedule else { return "" }
        guard let date = schedule.date, !date.isEmpty else {
            return "Your usual time, every morning."
        }
        if schedule.callTime == schedule.defaultTime {
            return "Set for \(date) - the same as your usual time."
        }
        return "Set for \(date). Your usual is \(MorningSchedule.display(schedule.defaultTime))."
    }

    // MARK: - Work

    private func load() async {
        do {
            let got = try await state.service.morningSchedule()
            schedule = got
            picked = Self.date(from: got.callTime) ?? picked
            phase = .ready
        } catch APIError.notFound {
            phase = .unavailable
        } catch {
            phase = .failed((error as? APIError)?.errorDescription
                            ?? ScreenState.loadFailed)
        }
    }

    private func save() async {
        isSaving = true
        saveError = nil
        defer { isSaving = false }
        let time = Self.time(from: picked)
        do {
            // No date: the contract reads an absent key as tomorrow, which is
            // the only day this screen offers to change.
            let got = try await state.service.setMorningSchedule(callTime: time, date: nil)
            schedule = got
            // Confirm with what came BACK, not with what was sent. If the
            // server rounded, clamped or refused the minute, the difference is
            // the one thing worth seeing.
            confirmation = "First call tomorrow: \(MorningSchedule.display(got.callTime))"
        } catch APIError.notFound {
            phase = .unavailable
        } catch {
            confirmation = nil
            saveError = (error as? APIError)?.errorDescription
                ?? "That didn't save. The time is unchanged."
        }
    }

    // MARK: - "HH:MM" <-> picker

    /// Reads back only the components the wheel actually shows. The date
    /// underneath is today's and is deliberately discarded.
    private static func time(from date: Date) -> String {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 7, parts.minute ?? 0)
    }

    private static func date(from time: String) -> Date? {
        let parts = time.split(separator: ":")
        guard parts.count >= 2, let hour = Int(parts[0]), let minute = Int(parts[1]) else {
            return nil
        }
        return Calendar.current.date(bySettingHour: hour, minute: minute,
                                     second: 0, of: Date())
    }
}

#Preview {
    NavigationStack {
        MorningCallScreen().environmentObject(AppState())
    }
}
