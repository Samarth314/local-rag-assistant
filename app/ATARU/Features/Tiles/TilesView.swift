import SwiftUI

// MARK: - Model

/// One tile as the production launcher describes it.
///
/// The grid is driven by the launcher's own manifest (`GET /api/launcher` on
/// the tiles host) so the phone shows exactly what the wall launcher shows -
/// same keys, same names, same health dots - with no per-tile hardcoding
/// here. When that host is unreachable (or not configured, as in Demo) the
/// grid falls back to the static `HomeTile` set.
struct LauncherTile: Decodable, Identifiable {
    let key: String
    let name: String
    let kind: String?
    let url: String?
    let up: Bool?

    var id: String { key }

    /// SF Symbol per launcher key; unknown keys get a neutral grid glyph so a
    /// new tile appears un-iconed rather than not at all.
    var symbol: String {
        switch key {
        case "chat":        return "waveform"
        case "plan":        return "checklist"
        case "dashboard":   return "gauge.with.dots.needle.50percent"
        case "jellyfin":    return "play.rectangle"
        case "navidrome":   return "music.note"
        case "vaultwarden": return "key"
        case "portainer":   return "shippingbox"
        case "ntfy":        return "bell.badge"
        case "finance":     return "dollarsign.circle"
        case "health":      return "heart.text.square"
        case "journal":     return "book.closed"
        case "home":        return "lightbulb"
        case "workspaces":  return "square.stack.3d.up"
        case "penecho":     return "scribble.variable"
        case "ingest":      return "tray.full"
        case "remote":      return "display"
        default:            return "square.grid.2x2"
        }
    }

    struct Manifest: Decodable {
        let tiles: [LauncherTile]
    }
}

// MARK: - View model

@MainActor
final class TilesViewModel: ObservableObject {
    @Published var tiles: [LauncherTile] = []
    @Published var usingFallback = false
    @Published var isLoading = false

    /// The launcher host, from build config (`ATARU_TILES_URL`). A different
    /// host from the assistant backend in Settings, deliberately: tiles are
    /// the front door to the whole homelab, not just the chat service.
    static var manifestURL: URL? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "ATARUTilesURL") as? String,
              !raw.trimmingCharacters(in: .whitespaces).isEmpty,
              let base = URL(string: raw) else { return nil }
        return base.appending(path: "api/launcher")
    }

    func refresh() async {
        isLoading = tiles.isEmpty
        defer { isLoading = false }
        guard let url = Self.manifestURL else { fallBack(); return }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 8
            let (data, _) = try await URLSession.shared.data(for: request)
            let manifest = try JSONDecoder().decode(LauncherTile.Manifest.self, from: data)
            guard !manifest.tiles.isEmpty else { fallBack(); return }
            tiles = manifest.tiles
            usingFallback = false
        } catch {
            fallBack()
        }
    }

    /// Static grid from the radial menu's tile set - the same destinations,
    /// just without live health dots.
    private func fallBack() {
        guard tiles.isEmpty || !usingFallback else { return }
        usingFallback = true
        tiles = HomeTile.allCases.map { tile in
            let url: String?
            if case .web(let u) = tile.destination { url = u.absoluteString } else { url = nil }
            return LauncherTile(key: tile.rawValue, name: tile.title,
                                kind: nil, url: url, up: nil)
        }
    }
}

// MARK: - Screen

/// Everything ATARU can show, one grid - the launcher wall, in the pocket.
struct TilesView: View {
    @EnvironmentObject private var state: AppState
    @StateObject private var model = TilesViewModel()

    /// Tiles that are native screens route through these; everything else
    /// opens its (mobile) web page in the app's browser sheet.
    let openAsk: () -> Void
    let openLibrary: () -> Void
    let openWeb: (URL) -> Void

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 220),
                                    spacing: Theme.Space.s)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: Theme.Space.s) {
                    NavigationLink {
                        PlanView()
                    } label: {
                        TileCell(symbol: "checklist", name: "Plan",
                                 kind: "Top 3 · todos", up: nil)
                    }
                    .buttonStyle(.plain)

                    ForEach(model.tiles.filter { $0.key != "plan" }) { tile in
                        Button {
                            open(tile)
                        } label: {
                            TileCell(symbol: tile.symbol, name: tile.name,
                                     kind: tile.kind, up: tile.up)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, Theme.Space.screen)
                .padding(.top, Theme.Space.s)
                .padding(.bottom, Theme.Space.xl)
            }
            .ataruBackdrop()
            .navigationTitle("Tiles")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable { await model.refresh() }
            .overlay {
                if model.isLoading {
                    ProgressView().tint(Theme.cyan)
                }
            }
        }
        .task { await model.refresh() }
    }

    private func open(_ tile: LauncherTile) {
        switch tile.key {
        case "chat", "assistant": openAsk()
        case "ingest", "documents": openLibrary()
        default:
            if let raw = tile.url, let url = URL(string: raw) { openWeb(url) }
        }
    }
}

// MARK: - Cell

/// One tile: glyph, name, quiet subtitle, live dot. Frosted panel on the
/// dark backdrop - the launcher wall's language at phone size.
private struct TileCell: View {
    let symbol: String
    let name: String
    let kind: String?
    let up: Bool?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack {
                Image(systemName: symbol)
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(Theme.cyan)
                Spacer(minLength: 0)
                if let up {
                    Circle()
                        .fill(up ? Theme.green : Theme.red)
                        .frame(width: 7, height: 7)
                        .opacity(0.9)
                        .accessibilityLabel(up ? "online" : "offline")
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.ataruLabel())
                    .foregroundStyle(Theme.textPrimary)
                if let kind, !kind.isEmpty {
                    Text(kind)
                        .font(.ataruCaption())
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
            }
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, minHeight: 108, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .fill(Theme.surface)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(Theme.border, lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card,
                                       style: .continuous))
    }
}

// MARK: - Plan (native tile)

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

/// The day's plan, natively: what the 7am call announces, editable by thumb.
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

#Preview {
    TilesView(openAsk: {}, openLibrary: {}, openWeb: { _ in })
        .environmentObject(AppState())
}
