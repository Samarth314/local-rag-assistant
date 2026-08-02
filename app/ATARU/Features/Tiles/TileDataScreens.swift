import Charts
import SwiftUI

// The six native data screens behind the tiles. Each fetches its view app's
// JSON API (prod or dev, per TileBackend) with all-optional decoders - the
// backends have documented failure variants where most keys vanish, so
// nothing here force-unwraps a payload field.

// MARK: - Shared bits

private struct ScreenState {
    static let loadFailed = "Couldn't reach this surface - check Tailscale and the server in Settings."
}

private struct SectionHeader: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.ataruCaption())
            .foregroundStyle(Theme.textTertiary)
            .kerning(1.5)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ErrorBanner: View {
    let message: String
    var body: some View {
        Label(message, systemImage: "wifi.exclamationmark")
            .font(.ataruCaption())
            .foregroundStyle(Theme.amber)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Finance

private enum FinanceDTO {
    struct Payload: Decodable {
        let ok: Bool?
        let demo: Bool?
        let networth: NetWorth?
        let spending: Spending?
        let subscriptions: Subscriptions?
    }
    struct NetWorth: Decodable {
        let ok: Bool?
        let total: Double?
        let breakdown: [Account]?
    }
    struct Account: Decodable {
        let family: String?
        let value: Double?
        let as_of: String?
        let stale: Bool?
    }
    struct Spending: Decodable {
        let months: [String]?
        let totals: [Double]?
        let latest_total: Double?
        let mom_pct: Double?
        let latest_by_cat: [Category]?
        let top_merchants: [Merchant]?
    }
    struct Category: Decodable {
        let category: String?
        let amount: Double?
    }
    struct Merchant: Decodable {
        let merchant: String?
        let amount: Double?
    }
    struct Subscriptions: Decodable {
        let active: [Sub]?
        let monthly_total: Double?
    }
    struct Sub: Decodable {
        let service: String?
        let amount: Double?
        let cadence: String?
        let monthly: Double?
    }
}

struct FinanceScreen: View {
    @EnvironmentObject private var state: AppState
    @State private var payload: FinanceDTO.Payload?
    @State private var failed = false

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Space.m) {
                if failed { ErrorBanner(message: ScreenState.loadFailed) }

                if let networth = payload?.networth, let total = networth.total {
                    ATCard {
                        VStack(alignment: .leading, spacing: Theme.Space.s) {
                            SectionHeader(text: "Net worth")
                            Text(money(total))
                                .font(.system(size: 34, weight: .thin))
                                .foregroundStyle(Theme.textPrimary)
                            ForEach((networth.breakdown ?? [])
                                .filter { $0.family != nil }, id: \.family) { account in
                                HStack {
                                    Text(account.family ?? "")
                                        .font(.ataruBody())
                                        .foregroundStyle(Theme.textSecondary)
                                    if account.stale == true {
                                        Text("stale")
                                            .font(.ataruCaption())
                                            .foregroundStyle(Theme.amber)
                                    }
                                    Spacer()
                                    Text(money(account.value ?? 0))
                                        .font(.ataruMono(13))
                                        .foregroundStyle(Theme.textPrimary)
                                }
                            }
                        }
                        .padding(Theme.Space.m)
                    }
                }

                if let spending = payload?.spending,
                   let months = spending.months, let totals = spending.totals,
                   !months.isEmpty, months.count == totals.count {
                    ATCard {
                        VStack(alignment: .leading, spacing: Theme.Space.s) {
                            HStack {
                                SectionHeader(text: "Spending")
                                if let mom = spending.mom_pct {
                                    Text(String(format: "%+.1f%% m/m", mom))
                                        .font(.ataruCaption())
                                        .foregroundStyle(mom > 0 ? Theme.amber : Theme.green)
                                }
                            }
                            Chart {
                                ForEach(Array(zip(months, totals).suffix(12)),
                                        id: \.0) { month, total in
                                    BarMark(
                                        x: .value("Month", String(month.suffix(2))),
                                        y: .value("Spend", total))
                                    .foregroundStyle(Theme.cyan.opacity(0.75))
                                }
                            }
                            .frame(height: 130)
                            .chartYAxis {
                                AxisMarks { AxisValueLabel().font(.system(size: 9)) }
                            }
                            ForEach((spending.latest_by_cat ?? []).prefix(6),
                                    id: \.category) { row in
                                HStack {
                                    Text(row.category ?? "")
                                        .font(.ataruBody())
                                        .foregroundStyle(Theme.textSecondary)
                                    Spacer()
                                    Text(money(row.amount ?? 0))
                                        .font(.ataruMono(13))
                                        .foregroundStyle(Theme.textPrimary)
                                }
                            }
                        }
                        .padding(Theme.Space.m)
                    }
                }

                if let subs = payload?.subscriptions, let active = subs.active,
                   !active.isEmpty {
                    ATCard {
                        VStack(alignment: .leading, spacing: Theme.Space.s) {
                            HStack {
                                SectionHeader(text: "Subscriptions")
                                Text("\(money(subs.monthly_total ?? 0))/mo")
                                    .font(.ataruCaption())
                                    .foregroundStyle(Theme.textSecondary)
                            }
                            ForEach(active, id: \.service) { sub in
                                HStack {
                                    Text(sub.service ?? "")
                                        .font(.ataruBody())
                                        .foregroundStyle(Theme.textSecondary)
                                    Spacer()
                                    Text("\(money(sub.amount ?? 0)) \(sub.cadence ?? "")")
                                        .font(.ataruMono(12))
                                        .foregroundStyle(Theme.textTertiary)
                                }
                            }
                        }
                        .padding(Theme.Space.m)
                    }
                }
            }
            .padding(Theme.Space.screen)
        }
        .ataruBackdrop()
        .navigationTitle(payload?.demo == true ? "Finance (demo)" : "Finance")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        guard let root = TileBackend.current(from: state).apiRoot(.finance) else { return }
        do {
            payload = try await TileFetch.get(
                FinanceDTO.Payload.self, root.appending(path: "api/finance"))
            failed = false
        } catch { failed = true }
    }

    private func money(_ value: Double) -> String {
        value.formatted(.currency(code: "USD").precision(.fractionLength(0)))
    }
}

// MARK: - Health

private enum HealthDTO {
    struct Payload: Decodable {
        let demo: Bool?
        let markers: [Marker]?
        let meds: Meds?
        let timeline: Timeline?
        let disclaimer: String?
        let panels: Panels?
    }
    struct Panels: Decodable {
        let latest_date: String?
        let flagged: Int?
    }
    struct Marker: Decodable {
        let key: String?
        let name: String?
        let unit: String?
        let latest: Latest?
        let points: [Point]?
    }
    struct Latest: Decodable {
        let date: String?
        let value: String?
        let flag: String?
        let range: String?
    }
    struct Point: Decodable {
        let date: String?
        let value: Double?
    }
    struct Meds: Decodable {
        let active: [Med]?
    }
    struct Med: Decodable {
        let med: String?
        let strength: String?
        let schedule: String?
    }
    struct Timeline: Decodable {
        let events: [Event]?
    }
    struct Event: Decodable {
        let date: String?
        let kind: String?
        let text: String?
    }
}

struct HealthScreen: View {
    @EnvironmentObject private var state: AppState
    @State private var payload: HealthDTO.Payload?
    @State private var failed = false

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Space.m) {
                if failed { ErrorBanner(message: ScreenState.loadFailed) }

                if let panels = payload?.panels, let date = panels.latest_date {
                    ATCard {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                SectionHeader(text: "Latest panel")
                                Text(date)
                                    .font(.ataruBody())
                                    .foregroundStyle(Theme.textPrimary)
                            }
                            Spacer()
                            if let flagged = panels.flagged, flagged > 0 {
                                Label("\(flagged) out of range",
                                      systemImage: "exclamationmark.triangle")
                                    .font(.ataruCaption())
                                    .foregroundStyle(Theme.amber)
                            }
                        }
                        .padding(Theme.Space.m)
                    }
                }

                if let markers = payload?.markers, !markers.isEmpty {
                    ATCard {
                        VStack(alignment: .leading, spacing: Theme.Space.s) {
                            SectionHeader(text: "Markers")
                            ForEach(markers, id: \.key) { marker in
                                HStack(spacing: Theme.Space.s) {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(marker.name ?? "")
                                            .font(.ataruBody())
                                            .foregroundStyle(Theme.textPrimary)
                                        if let latest = marker.latest {
                                            Text("\(latest.value ?? "") \(marker.unit ?? "") · \(latest.date ?? "")")
                                                .font(.ataruCaption())
                                                .foregroundStyle(flagColor(latest.flag))
                                        }
                                    }
                                    Spacer()
                                    if let points = marker.points, points.count > 1 {
                                        Chart {
                                            ForEach(Array(points.enumerated()),
                                                    id: \.offset) { _, point in
                                                if let value = point.value {
                                                    LineMark(
                                                        x: .value("Date", point.date ?? ""),
                                                        y: .value("Value", value))
                                                    .foregroundStyle(Theme.cyan)
                                                }
                                            }
                                        }
                                        .chartXAxis(.hidden)
                                        .chartYAxis(.hidden)
                                        .frame(width: 72, height: 26)
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                        }
                        .padding(Theme.Space.m)
                    }
                }

                if let meds = payload?.meds?.active, !meds.isEmpty {
                    ATCard {
                        VStack(alignment: .leading, spacing: Theme.Space.s) {
                            SectionHeader(text: "Active meds")
                            ForEach(meds, id: \.med) { med in
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("\(med.med ?? "") \(med.strength ?? "")")
                                        .font(.ataruBody())
                                        .foregroundStyle(Theme.textPrimary)
                                    Text(med.schedule ?? "")
                                        .font(.ataruCaption())
                                        .foregroundStyle(Theme.textTertiary)
                                }
                            }
                        }
                        .padding(Theme.Space.m)
                    }
                }

                if let events = payload?.timeline?.events, !events.isEmpty {
                    ATCard {
                        VStack(alignment: .leading, spacing: Theme.Space.s) {
                            SectionHeader(text: "Timeline")
                            ForEach(Array(events.prefix(6).enumerated()),
                                    id: \.offset) { _, event in
                                HStack(alignment: .top, spacing: Theme.Space.s) {
                                    Text(event.date ?? "")
                                        .font(.ataruMono(11))
                                        .foregroundStyle(Theme.textTertiary)
                                    Text(event.text ?? "")
                                        .font(.ataruCaption())
                                        .foregroundStyle(Theme.textSecondary)
                                }
                            }
                        }
                        .padding(Theme.Space.m)
                    }
                }

                if let disclaimer = payload?.disclaimer {
                    Text(disclaimer)
                        .font(.ataruCaption())
                        .foregroundStyle(Theme.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(Theme.Space.screen)
        }
        .ataruBackdrop()
        .navigationTitle(payload?.demo == true ? "Health (demo)" : "Health")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
    }

    private func flagColor(_ flag: String?) -> Color {
        switch flag {
        case "high", "low": return Theme.amber
        default: return Theme.textTertiary
        }
    }

    private func load() async {
        guard let root = TileBackend.current(from: state).apiRoot(.health) else { return }
        do {
            payload = try await TileFetch.get(
                HealthDTO.Payload.self, root.appending(path: "api/health"))
            failed = false
        } catch { failed = true }
    }
}

// MARK: - Home

private enum HomeDTO {
    struct Payload: Decodable {
        let ok: Bool?
        let error: String?
        let devices: [Device]?
        let sensors: [Device]?
    }
    struct Device: Decodable {
        let entity_id: String?
        let domain: String?
        let name: String?
        let state: String?
        let attrs: Attrs?
    }
    struct Attrs: Decodable {
        let brightness: Double?
        let temperature: Double?
        let current_temperature: Double?
        let unit_of_measurement: String?
        let percentage: Double?
        let current_power_w: Double?
    }
    struct ToggleReply: Decodable {
        let ok: Bool?
        let device: Device?
        let error: String?
    }
    struct ToggleBody: Encodable {
        let entity_id: String
        let action: String
    }
}

struct HomeScreen: View {
    @EnvironmentObject private var state: AppState
    @State private var payload: HomeDTO.Payload?
    @State private var failed = false
    @State private var busyEntity: String?

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Space.m) {
                if failed { ErrorBanner(message: ScreenState.loadFailed) }
                if let error = payload?.error {
                    ErrorBanner(message: error)
                }

                if let devices = payload?.devices, !devices.isEmpty {
                    ATCard {
                        VStack(alignment: .leading, spacing: Theme.Space.s) {
                            SectionHeader(text: "Devices")
                            ForEach(devices, id: \.entity_id) { device in
                                HStack {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(device.name ?? device.entity_id ?? "")
                                            .font(.ataruBody())
                                            .foregroundStyle(Theme.textPrimary)
                                        Text(detail(device))
                                            .font(.ataruCaption())
                                            .foregroundStyle(Theme.textTertiary)
                                    }
                                    Spacer()
                                    if busyEntity == device.entity_id {
                                        ProgressView().tint(Theme.cyan)
                                    } else {
                                        Toggle("", isOn: Binding(
                                            get: { device.state == "on" },
                                            set: { on in
                                                Task { await toggle(device, on: on) }
                                            }))
                                        .labelsHidden()
                                        .tint(Theme.cyan)
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                        }
                        .padding(Theme.Space.m)
                    }
                }

                if let sensors = payload?.sensors, !sensors.isEmpty {
                    ATCard {
                        VStack(alignment: .leading, spacing: Theme.Space.s) {
                            SectionHeader(text: "Sensors")
                            ForEach(sensors, id: \.entity_id) { sensor in
                                HStack {
                                    Text(sensor.name ?? sensor.entity_id ?? "")
                                        .font(.ataruBody())
                                        .foregroundStyle(Theme.textSecondary)
                                    Spacer()
                                    Text("\(sensor.state ?? "?") \(sensor.attrs?.unit_of_measurement ?? "")")
                                        .font(.ataruMono(13))
                                        .foregroundStyle(Theme.textPrimary)
                                }
                            }
                        }
                        .padding(Theme.Space.m)
                    }
                }
            }
            .padding(Theme.Space.screen)
        }
        .ataruBackdrop()
        .navigationTitle("Home")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
    }

    private func detail(_ device: HomeDTO.Device) -> String {
        var parts: [String] = [device.state ?? "?"]
        if let brightness = device.attrs?.brightness {
            parts.append("\(Int(brightness / 2.55))%")
        }
        if let pct = device.attrs?.percentage { parts.append("\(Int(pct))%") }
        if let temp = device.attrs?.current_temperature {
            parts.append("\(temp)°")
        }
        return parts.joined(separator: " · ")
    }

    private func load() async {
        guard let root = TileBackend.current(from: state).apiRoot(.home) else { return }
        do {
            payload = try await TileFetch.get(
                HomeDTO.Payload.self, root.appending(path: "api/home"))
            failed = false
        } catch { failed = true }
    }

    private func toggle(_ device: HomeDTO.Device, on: Bool) async {
        guard let entity = device.entity_id,
              let root = TileBackend.current(from: state).apiRoot(.home) else { return }
        busyEntity = entity
        defer { busyEntity = nil }
        _ = try? await TileFetch.post(
            HomeDTO.ToggleReply.self, root.appending(path: "api/toggle"),
            body: HomeDTO.ToggleBody(entity_id: entity, action: on ? "on" : "off"))
        await load()
    }
}

// MARK: - Status

private enum StatusDTO {
    struct Payload: Decodable {
        let demo: Bool?
        let machines: [String: Machine]?
        let services: [Service]?
        let vault: Vault?
    }
    struct Machine: Decodable {
        let ok: Bool?
        let label: String?
        let sub: String?
        let cpu: Double?
        let mem_pct: Double?
        let disk_pct: Double?
        let temp: Double?
        let pressure: String?
        let uptime_s: Double?
        let error: String?
    }
    struct Service: Decodable {
        let name: String?
        let up: Bool?
        let kind: String?
    }
    struct Vault: Decodable {
        let commit: String?
        let subject: String?
        let rel: String?
        let dirty: Int?
        let size: String?
    }
}

struct StatusScreen: View {
    @EnvironmentObject private var state: AppState
    @State private var payload: StatusDTO.Payload?
    @State private var failed = false

    private let machineOrder = ["mini", "orin", "nas"]

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Space.m) {
                if failed { ErrorBanner(message: ScreenState.loadFailed) }

                ForEach(machineOrder, id: \.self) { key in
                    if let machine = payload?.machines?[key] {
                        ATCard {
                            VStack(alignment: .leading, spacing: Theme.Space.s) {
                                HStack {
                                    SectionHeader(text: machine.label ?? key)
                                    Circle()
                                        .fill(machine.ok == true ? Theme.green : Theme.red)
                                        .frame(width: 7, height: 7)
                                }
                                if machine.ok == true {
                                    HStack(spacing: Theme.Space.m) {
                                        stat("CPU", machine.cpu, suffix: "%")
                                        stat("Mem", machine.mem_pct, suffix: "%")
                                        stat("Disk", machine.disk_pct, suffix: "%")
                                        if let temp = machine.temp {
                                            stat("Temp", temp, suffix: "°")
                                        } else if let pressure = machine.pressure {
                                            VStack(alignment: .leading, spacing: 1) {
                                                Text("Pressure")
                                                    .font(.ataruCaption())
                                                    .foregroundStyle(Theme.textTertiary)
                                                Text(pressure)
                                                    .font(.ataruMono(13))
                                                    .foregroundStyle(Theme.textPrimary)
                                            }
                                        }
                                        Spacer()
                                    }
                                } else {
                                    Text(machine.error ?? "unreachable")
                                        .font(.ataruCaption())
                                        .foregroundStyle(Theme.textTertiary)
                                }
                            }
                            .padding(Theme.Space.m)
                        }
                    }
                }

                if let services = payload?.services, !services.isEmpty {
                    ATCard {
                        VStack(alignment: .leading, spacing: Theme.Space.s) {
                            SectionHeader(text: "Services")
                            ForEach(services, id: \.name) { service in
                                HStack {
                                    Circle()
                                        .fill(service.up == true ? Theme.green : Theme.red)
                                        .frame(width: 7, height: 7)
                                    Text(service.name ?? "")
                                        .font(.ataruBody())
                                        .foregroundStyle(Theme.textSecondary)
                                    Spacer()
                                }
                            }
                        }
                        .padding(Theme.Space.m)
                    }
                }

                if let vault = payload?.vault, let commit = vault.commit {
                    ATCard {
                        VStack(alignment: .leading, spacing: Theme.Space.xs) {
                            SectionHeader(text: "Vault")
                            Text("\(commit) · \(vault.rel ?? "")")
                                .font(.ataruMono(12))
                                .foregroundStyle(Theme.textPrimary)
                            Text(vault.subject ?? "")
                                .font(.ataruCaption())
                                .foregroundStyle(Theme.textSecondary)
                                .lineLimit(2)
                            if let dirty = vault.dirty, dirty > 0 {
                                Text("\(dirty) dirty files")
                                    .font(.ataruCaption())
                                    .foregroundStyle(Theme.amber)
                            }
                        }
                        .padding(Theme.Space.m)
                    }
                }
            }
            .padding(Theme.Space.screen)
        }
        .ataruBackdrop()
        .navigationTitle(payload?.demo == true ? "Status (demo)" : "Status")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
    }

    private func stat(_ label: String, _ value: Double?, suffix: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.ataruCaption())
                .foregroundStyle(Theme.textTertiary)
            Text(value.map { String(format: "%.0f%@", $0, suffix) } ?? "—")
                .font(.ataruMono(13))
                .foregroundStyle(Theme.textPrimary)
        }
    }

    private func load() async {
        guard let root = TileBackend.current(from: state).apiRoot(.status) else { return }
        do {
            payload = try await TileFetch.get(
                StatusDTO.Payload.self, root.appending(path: "api/dashboard"))
            failed = false
        } catch { failed = true }
    }
}

// MARK: - Journal

private enum JournalDTO {
    struct List: Decodable {
        let entries: [Entry]?
    }
    struct Entry: Decodable {
        let path: String?
        let title: String?
        let date: String?
        let isPrivate: Bool?
        let preview: String?

        enum CodingKeys: String, CodingKey {
            case path, title, date, preview
            case isPrivate = "private"
        }
    }
    struct Detail: Decodable {
        let title: String?
        let date: String?
        let body: String?
    }
    struct CreateBody: Encodable {
        let title: String
        let body: String
        let commit = true
    }
    struct CreateReply: Decodable {
        let ok: Bool?
        let path: String?
    }
}

struct JournalScreen: View {
    @EnvironmentObject private var state: AppState
    @State private var entries: [JournalDTO.Entry] = []
    @State private var failed = false
    @State private var composing = false

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Space.s) {
                if failed { ErrorBanner(message: ScreenState.loadFailed) }

                ForEach(entries, id: \.path) { entry in
                    NavigationLink {
                        JournalEntryScreen(path: entry.path ?? "")
                    } label: {
                        ATCard {
                            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                                HStack {
                                    Text(entry.title?.isEmpty == false
                                         ? entry.title! : "Untitled")
                                        .font(.ataruLabel())
                                        .foregroundStyle(Theme.textPrimary)
                                    if entry.isPrivate == true {
                                        Image(systemName: "lock")
                                            .font(.system(size: 11))
                                            .foregroundStyle(Theme.textTertiary)
                                    }
                                    Spacer()
                                    Text(entry.date ?? "")
                                        .font(.ataruMono(11))
                                        .foregroundStyle(Theme.textTertiary)
                                }
                                Text(entry.preview ?? "")
                                    .font(.ataruCaption())
                                    .foregroundStyle(Theme.textSecondary)
                                    .lineLimit(2)
                            }
                            .padding(Theme.Space.m)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(Theme.Space.screen)
        }
        .ataruBackdrop()
        .navigationTitle("Journal")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    composing = true
                } label: {
                    Image(systemName: "square.and.pencil")
                        .foregroundStyle(Theme.cyan)
                }
                .accessibilityLabel("New entry")
            }
        }
        .sheet(isPresented: $composing, onDismiss: { Task { await load() } }) {
            JournalComposeScreen()
                .environmentObject(state)
        }
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        guard let root = TileBackend.current(from: state).apiRoot(.journal) else { return }
        do {
            let list = try await TileFetch.get(
                JournalDTO.List.self, root.appending(path: "api/entries"))
            entries = list.entries ?? []
            failed = false
        } catch { failed = true }
    }
}

private struct JournalEntryScreen: View {
    @EnvironmentObject private var state: AppState
    let path: String
    @State private var detail: JournalDTO.Detail?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text(detail?.date ?? "")
                    .font(.ataruMono(11))
                    .foregroundStyle(Theme.textTertiary)
                Text(detail?.body ?? "")
                    .font(.ataruBody())
                    .foregroundStyle(Theme.textPrimary)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Space.screen)
        }
        .ataruBackdrop()
        .navigationTitle(detail?.title ?? "Entry")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard let root = TileBackend.current(from: state).apiRoot(.journal),
                  var comps = URLComponents(
                    url: root.appending(path: "api/entry"),
                    resolvingAgainstBaseURL: false) else { return }
            comps.queryItems = [URLQueryItem(name: "path", value: path)]
            guard let url = comps.url else { return }
            detail = try? await TileFetch.get(JournalDTO.Detail.self, url)
        }
    }
}

private struct JournalComposeScreen: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var body_ = ""
    @State private var saving = false

    var body: some View {
        NavigationStack {
            VStack(spacing: Theme.Space.s) {
                TextField("Title", text: $title)
                    .font(.ataruLabel())
                    .padding(Theme.Space.m)
                    .background(Theme.surface,
                                in: RoundedRectangle(cornerRadius: Theme.Radius.tile))
                TextEditor(text: $body_)
                    .font(.ataruBody())
                    .scrollContentBackground(.hidden)
                    .padding(Theme.Space.s)
                    .background(Theme.surface,
                                in: RoundedRectangle(cornerRadius: Theme.Radius.tile))
            }
            .padding(Theme.Space.screen)
            .ataruBackdrop()
            .navigationTitle("New entry")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Theme.textSecondary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(saving ? "Saving…" : "Save") {
                        Task { await save() }
                    }
                    .disabled(saving ||
                              body_.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .foregroundStyle(Theme.cyan)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func save() async {
        guard let root = TileBackend.current(from: state).apiRoot(.journal) else { return }
        saving = true
        defer { saving = false }
        let reply = try? await TileFetch.post(
            JournalDTO.CreateReply.self, root.appending(path: "api/entry"),
            body: JournalDTO.CreateBody(title: title, body: body_))
        if reply?.ok == true { dismiss() }
    }
}

// MARK: - Workspaces

private enum SpacesDTO {
    struct List: Decodable {
        let workspaces: [Space]?
    }
    struct Space: Decodable {
        let slug: String?
        let name: String?
        let description: String?
        let status: String?
        let kind: String?
        let counts: Counts?
    }
    struct Counts: Decodable {
        let resources: Int?
        let notes: Int?
        let tasks_open: Int?
        let tasks_total: Int?
    }
    struct Detail: Decodable {
        let name: String?
        let readme: String?
        let notes: [Note]?
        let tasks: [WorkTask]?
        let resources: [Resource]?
    }
    struct Note: Decodable {
        let date: String?
        let title: String?
        let body: String?
    }
    struct WorkTask: Decodable {
        let id: Int?
        let done: Bool?
        let text: String?
    }
    struct Resource: Decodable {
        let name: String?
        let rel: String?
    }
    struct TaskBody: Encodable {
        let slug: String
        let action: String
        let text: String?
        let index: Int?
    }
    struct TaskReply: Decodable {
        let ok: Bool?
        let tasks: [WorkTask]?
    }
}

struct WorkspacesScreen: View {
    @EnvironmentObject private var state: AppState
    @State private var spaces: [SpacesDTO.Space] = []
    @State private var failed = false

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Space.s) {
                if failed { ErrorBanner(message: ScreenState.loadFailed) }

                ForEach(spaces, id: \.slug) { space in
                    NavigationLink {
                        WorkspaceDetailScreen(slug: space.slug ?? "")
                    } label: {
                        ATCard {
                            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                                HStack {
                                    Text(space.name ?? space.slug ?? "")
                                        .font(.ataruLabel())
                                        .foregroundStyle(Theme.textPrimary)
                                    Spacer()
                                    Text(space.status ?? "")
                                        .font(.ataruCaption())
                                        .foregroundStyle(space.status == "active"
                                                         ? Theme.green : Theme.textTertiary)
                                }
                                if let description = space.description,
                                   !description.isEmpty {
                                    Text(description)
                                        .font(.ataruCaption())
                                        .foregroundStyle(Theme.textSecondary)
                                        .lineLimit(2)
                                }
                                if let counts = space.counts {
                                    Text("\(counts.tasks_open ?? 0)/\(counts.tasks_total ?? 0) tasks open · \(counts.notes ?? 0) notes · \(counts.resources ?? 0) files")
                                        .font(.ataruCaption())
                                        .foregroundStyle(Theme.textTertiary)
                                }
                            }
                            .padding(Theme.Space.m)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(Theme.Space.screen)
        }
        .ataruBackdrop()
        .navigationTitle("Workspaces")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        guard let root = TileBackend.current(from: state).apiRoot(.workspaces) else { return }
        do {
            let list = try await TileFetch.get(
                SpacesDTO.List.self, root.appending(path: "api/workspaces"))
            spaces = list.workspaces ?? []
            failed = false
        } catch { failed = true }
    }
}

private struct WorkspaceDetailScreen: View {
    @EnvironmentObject private var state: AppState
    let slug: String
    @State private var detail: SpacesDTO.Detail?
    @State private var newTask = ""

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Space.m) {
                if let readme = detail?.readme, !readme.isEmpty {
                    ATCard {
                        Text(readme)
                            .font(.ataruCaption())
                            .foregroundStyle(Theme.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(Theme.Space.m)
                    }
                }

                ATCard {
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        SectionHeader(text: "Tasks")
                        ForEach(detail?.tasks ?? [], id: \.id) { task in
                            HStack(spacing: Theme.Space.s) {
                                Button {
                                    Task { await taskAction("toggle", index: task.id) }
                                } label: {
                                    Image(systemName: task.done == true
                                          ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(task.done == true
                                                         ? Theme.green : Theme.textTertiary)
                                }
                                Text(task.text ?? "")
                                    .font(.ataruBody())
                                    .foregroundStyle(task.done == true
                                                     ? Theme.textTertiary : Theme.textPrimary)
                                    .strikethrough(task.done == true)
                                Spacer()
                            }
                        }
                        HStack(spacing: Theme.Space.s) {
                            TextField("Add a task", text: $newTask)
                                .textFieldStyle(.plain)
                                .font(.ataruBody())
                                .onSubmit { submitTask() }
                            Button { submitTask() } label: {
                                Image(systemName: "plus.circle.fill")
                                    .foregroundStyle(Theme.cyan)
                            }
                        }
                    }
                    .padding(Theme.Space.m)
                }

                if let notes = detail?.notes, !notes.isEmpty {
                    ATCard {
                        VStack(alignment: .leading, spacing: Theme.Space.s) {
                            SectionHeader(text: "Notes")
                            ForEach(Array(notes.prefix(5).enumerated()),
                                    id: \.offset) { _, note in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(note.date ?? "")
                                        .font(.ataruMono(11))
                                        .foregroundStyle(Theme.textTertiary)
                                    Text(note.body ?? "")
                                        .font(.ataruCaption())
                                        .foregroundStyle(Theme.textSecondary)
                                        .lineLimit(4)
                                }
                            }
                        }
                        .padding(Theme.Space.m)
                    }
                }

                if let resources = detail?.resources, !resources.isEmpty {
                    ATCard {
                        VStack(alignment: .leading, spacing: Theme.Space.s) {
                            SectionHeader(text: "Files")
                            ForEach(resources, id: \.rel) { resource in
                                Label(resource.name ?? "",
                                      systemImage: "doc")
                                    .font(.ataruCaption())
                                    .foregroundStyle(Theme.textSecondary)
                            }
                        }
                        .padding(Theme.Space.m)
                    }
                }
            }
            .padding(Theme.Space.screen)
        }
        .ataruBackdrop()
        .navigationTitle(detail?.name ?? slug)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func submitTask() {
        let text = newTask.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        newTask = ""
        Task { await taskAction("add", text: text) }
    }

    private func taskAction(_ action: String, text: String? = nil,
                            index: Int? = nil) async {
        guard let root = TileBackend.current(from: state).apiRoot(.workspaces) else { return }
        let reply = try? await TileFetch.post(
            SpacesDTO.TaskReply.self, root.appending(path: "api/workspace/task"),
            body: SpacesDTO.TaskBody(slug: slug, action: action,
                                     text: text, index: index))
        if let tasks = reply?.tasks {
            detail = SpacesDTO.Detail(name: detail?.name, readme: detail?.readme,
                                      notes: detail?.notes, tasks: tasks,
                                      resources: detail?.resources)
        }
    }

    private func load() async {
        guard let root = TileBackend.current(from: state).apiRoot(.workspaces),
              var comps = URLComponents(
                url: root.appending(path: "api/workspace"),
                resolvingAgainstBaseURL: false) else { return }
        comps.queryItems = [URLQueryItem(name: "slug", value: slug)]
        guard let url = comps.url else { return }
        detail = try? await TileFetch.get(SpacesDTO.Detail.self, url)
    }
}
