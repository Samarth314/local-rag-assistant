import SwiftUI

@MainActor
final class PlanViewModel: ObservableObject {
    @Published var plan: DailyPlan = .empty()
    @Published var errorMessage: String?
    @Published var isLoading = false
    /// True while a row change is in flight.
    ///
    /// THE ROW THIS PROTECTS. The plan API addresses items by their POSITION -
    /// `{section, index}` is the whole of it, there is no id on a `PlanItem`
    /// and none in the reply - and every mutation returns a freshly reshuffled
    /// list. So two quick taps meant the second one carried an index computed
    /// against a list the first was in the middle of replacing, and the row
    /// that got removed or ticked was not the row that was touched. Nothing in
    /// the API can fix that from here, so the rows are simply not tappable
    /// while one change is outstanding: a mutation is a round trip and the
    /// list is correct again the moment it lands.
    @Published private(set) var isMutating = false

    private var service: ATARUService?

    func update(service: ATARUService) {
        self.service = service
    }

    func refresh() async {
        guard let service else { return }
        isLoading = plan.top3.isEmpty && plan.also.isEmpty
        defer { isLoading = false }
        await run { try await service.plan() }
    }

    /// Returns whether the server took it, so the field is only cleared when
    /// the text has landed somewhere other than the field.
    @discardableResult
    func add(_ text: String, top3: Bool) async -> Bool {
        guard let service, !isMutating else { return false }
        return await mutate { try await service.planAdd(text, top3: top3) }
    }

    func toggle(section: String, index: Int, done: Bool) async {
        guard let service, !isMutating else { return }
        await mutate { try await service.planSetDone(section: section, index: index, done: done) }
    }

    func remove(section: String, index: Int) async {
        guard let service, !isMutating else { return }
        await mutate { try await service.planRemove(section: section, index: index) }
    }

    private func mutate(_ op: () async throws -> DailyPlan) async -> Bool {
        isMutating = true
        defer { isMutating = false }
        return await run(op)
    }

    @discardableResult
    private func run(_ op: () async throws -> DailyPlan) async -> Bool {
        do {
            plan = try await op()
            errorMessage = nil
            return true
        } catch is CancellationError {
            return false
        } catch {
            errorMessage = (error as? APIError)?.localizedDescription
                ?? "Couldn't reach the plan - check the connection in Settings."
            return false
        }
    }
}

/// The day's plan, natively: what the morning call announces, editable by
/// thumb. The same vault file the call writes by voice.
struct PlanView: View {
    @EnvironmentObject private var state: AppState
    @StateObject private var model = PlanViewModel()
    @State private var newTop3 = ""
    @State private var newAlso = ""
    @FocusState private var focusedField: String?

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Space.m) {
                if let message = model.errorMessage {
                    Label(message, systemImage: "wifi.exclamationmark")
                        .font(.ataruCaption())
                        .foregroundStyle(Theme.amber)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Theme.Space.xs)
                }

                planSection(title: "Top 3", section: "top3",
                            items: model.plan.top3, numbered: true,
                            emptyText: "No main things set yet - the morning call will ask.",
                            input: $newTop3,
                            placeholder: "Add a main thing (max 3)",
                            showInput: model.plan.top3.count < 3, isTop3: true)

                planSection(title: "Also", section: "also",
                            items: model.plan.also, numbered: false,
                            emptyText: "Nothing else on the list.",
                            input: $newAlso, placeholder: "Add a task",
                            showInput: true, isTop3: false)

                Text("Voice works anywhere, including on the call: \"my three things today are…\", \"add X to my todo list\", \"mark X done\".")
                    .font(.ataruCaption())
                    .foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Theme.Space.xs)
            }
            .padding(.horizontal, Theme.Space.screen)
            .padding(.vertical, Theme.Space.m)
        }
        .scrollDismissesKeyboard(.interactively)
        .ataruBackdrop()
        .navigationTitle("Plan")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focusedField = nil }
                    .font(.ataruLabel())
            }
        }
        .refreshable { await model.refresh() }
        // Keyed on the generation, never on `ObjectIdentifier(state.service)`
        // - that is the object's ADDRESS, and a replacement service can be
        // handed the address the old one just freed, in which case the id does
        // not change and this task never re-runs. Every other screen moved off
        // it; this was the last one on it. See AppState.serviceGeneration.
        .task(id: state.serviceGeneration) {
            model.update(service: state.service)
            await model.refresh()
        }
    }

    @ViewBuilder
    private func planSection(title: String, section: String, items: [PlanItem],
                             numbered: Bool, emptyText: String,
                             input: Binding<String>, placeholder: String,
                             showInput: Bool, isTop3: Bool) -> some View {
        ATCard {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text(title.uppercased())
                    .font(.ataruCaption())
                    .foregroundStyle(Theme.textTertiary)
                    .kerning(1.5)

                if items.isEmpty {
                    Text(emptyText)
                        .font(.ataruCaption())
                        .foregroundStyle(Theme.textTertiary)
                }

                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(spacing: Theme.Space.s) {
                        if numbered {
                            Text("\(index + 1)")
                                .font(.ataruMono(12))
                                .foregroundStyle(Theme.cyan)
                                .frame(width: 14)
                        }
                        Button {
                            Task { await model.toggle(section: section,
                                                      index: index,
                                                      done: !item.done) }
                        } label: {
                            Image(systemName: item.done
                                  ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 20, weight: .light))
                                .foregroundStyle(item.done ? Theme.green : Theme.textTertiary)
                                .hitTarget()
                        }
                        .disabled(model.isMutating)
                        .accessibilityLabel(item.done ? "Mark not done" : "Mark done")
                        Text(item.text)
                            .font(.ataruBody())
                            .foregroundStyle(item.done ? Theme.textTertiary : Theme.textPrimary)
                            .strikethrough(item.done, color: Theme.textTertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button {
                            Task { await model.remove(section: section, index: index) }
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.textTertiary)
                                .hitTarget()
                        }
                        .accessibilityLabel("Remove \(item.text)")
                        // Every row addresses the server by index, so no row
                        // may be touched while an earlier change is still
                        // reshuffling the list. See PlanViewModel.isMutating.
                        .disabled(model.isMutating)
                    }
                    .padding(.vertical, 2)
                    .opacity(model.isMutating ? 0.55 : 1)
                }

                if showInput {
                    HStack(spacing: Theme.Space.s) {
                        TextField(placeholder, text: input)
                            .dismissExclusion()
                            .textFieldStyle(.plain)
                            .font(.ataruBody())
                            .foregroundStyle(Theme.textPrimary)
                            .focused($focusedField, equals: section)
                            .submitLabel(.done)
                            .onSubmit { submit(input, isTop3: isTop3) }
                        Button {
                            submit(input, isTop3: isTop3)
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 22))
                                .foregroundStyle(
                                    input.wrappedValue.trimmingCharacters(
                                        in: .whitespaces).isEmpty
                                    ? Theme.textTertiary : Theme.cyan)
                        }
                    }
                    .padding(.top, Theme.Space.xs)
                }
            }
            .padding(Theme.Space.m)
        }
    }

    /// The field is cleared by the server taking the item, not by the tap: a
    /// failed add used to empty the field and leave the text nowhere.
    private func submit(_ input: Binding<String>, isTop3: Bool) {
        let text = input.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !model.isMutating else { return }
        focusedField = nil
        Task {
            if await model.add(text, top3: isTop3) { input.wrappedValue = "" }
        }
    }
}
