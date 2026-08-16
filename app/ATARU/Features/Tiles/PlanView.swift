import SwiftUI

@MainActor
final class PlanViewModel: ObservableObject {
    @Published var plan: DailyPlan = .empty()
    @Published var errorMessage: String?
    @Published var isLoading = false

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

    func add(_ text: String, top3: Bool) async {
        guard let service else { return }
        await run { try await service.planAdd(text, top3: top3) }
    }

    func toggle(section: String, index: Int, done: Bool) async {
        guard let service else { return }
        await run { try await service.planSetDone(section: section, index: index, done: done) }
    }

    func remove(section: String, index: Int) async {
        guard let service else { return }
        await run { try await service.planRemove(section: section, index: index) }
    }

    private func run(_ op: () async throws -> DailyPlan) async {
        do {
            plan = try await op()
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't reach the plan - check the connection in Settings."
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
        .task(id: ObjectIdentifier(state.service)) {
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
                        }
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
                        }
                        .accessibilityLabel("Remove \(item.text)")
                    }
                    .padding(.vertical, 2)
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

    private func submit(_ input: Binding<String>, isTop3: Bool) {
        let text = input.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        input.wrappedValue = ""
        focusedField = nil
        Task { await model.add(text, top3: isTop3) }
    }
}
