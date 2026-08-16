import Charts
import SwiftUI

// The six native data screens behind the tiles. Each fetches its view app's
// JSON API (prod or dev, per TileBackend) with all-optional decoders - the
// backends have documented failure variants where most keys vanish, so
// nothing here force-unwraps a payload field.

// MARK: - Shared bits

// The tile screens' shared vocabulary. Internal rather than private since the
// set outgrew this one file - MorningCallScreen is a tile screen too, and a
// second copy of "Couldn't reach this surface" is how two screens start
// wording the same failure differently.

struct ScreenState {
    /// ONE RULE ABOUT LOADING, everywhere in the app.
    ///
    /// A refresh over content that is already on screen shows nothing. No
    /// spinner, no "Checking…", no row that appears and pushes the page down.
    /// The content simply becomes newer, and the only thing a refresh may ever
    /// put on screen is a failure - and then only the quiet one-line kind.
    ///
    /// The version of this that shipped had a fixed-height "Checking devices"
    /// row, on the reasoning that fixing its height stopped the page jumping.
    /// It still inserted a row, still shifted everything below it, and still
    /// announced a thing nobody asked to be told. A refresh is not an event.
    ///
    /// A first load with nothing cached may show a minimal centred indicator,
    /// because then there genuinely is nothing else on the screen.
    /// Note the wording: "load", not "reach". The old string said "Couldn't
    /// reach this surface - check Tailscale…", which is a claim about the
    /// network that none of these screens ever actually tested - and it was
    /// shown for decode failures and HTTP errors too. Sending someone to
    /// check Tailscale over a 502 is worse than saying nothing.
    static let loadFailed = "Couldn't load this surface - check the server in Settings."

    /// The reachability claim, now only used where reachability really was the
    /// problem. See `TileFetchError`.
    static let unreachable = "Couldn't reach this surface - check Tailscale and the server in Settings."
}

struct SectionHeader: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.ataruCaption())
            .foregroundStyle(Theme.textTertiary)
            .kerning(1.5)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A quieter banner, for something that went wrong beside content that is
/// still good. `ErrorBanner` is for a screen that has nothing to show; this is
/// for a screen that has everything to show and one stale corner.
struct InlineNote: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.ataruCaption())
            .foregroundStyle(Theme.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .transition(.opacity)
    }
}

struct ErrorBanner: View {
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
    // Codable, not just Decodable: the last payload is written back to disk so
    // the screen has something to draw before the network answers. See HomeCache.
    struct Payload: Codable {
        let ok: Bool?
        let error: String?
        let devices: [Device]?
        /// Absent on a server that has not been extended yet, and empty when
        /// no thermostat is paired. Both render nothing at all - a "no
        /// thermostat" placeholder is a row about the absence of a thing.
        let climate: [Climate]?
    }

    struct Climate: Codable, Identifiable {
        let entity_id: String?
        let name: String?
        let current_temp: Double?
        let target_temp: Double?
        let target_temp_low: Double?
        let target_temp_high: Double?
        /// heat | cool | heat_cool | off
        let hvac_mode: String?
        /// What it is doing right now - heating, cooling, idle.
        let hvac_action: String?
        let humidity: Double?

        var id: String { entity_id ?? name ?? UUID().uuidString }

        /// A band rather than a single setpoint. The POST contract carries one
        /// `temperature`, so a band cannot be set from here - the card shows it
        /// and hides its steppers rather than pretending otherwise.
        var isRange: Bool {
            hvac_mode == "heat_cool" && target_temp_low != nil && target_temp_high != nil
        }
    }

    struct ClimateReply: Decodable {
        let ok: Bool?
        let error: String?
        /// The verified object, when the server nests it. The contract reads
        /// as though it may instead be spread across the top level, so this is
        /// optional and the reconcile falls back to a plain refresh - both
        /// paths are silent, and neither guesses.
        let climate: Climate?
    }

    struct ClimateBody: Encodable {
        let entity_id: String
        let temperature: Double?
        let hvac_mode: String?
    }
    struct Device: Codable {
        let entity_id: String?
        let domain: String?
        let name: String?
        let state: String?
        let attrs: Attrs?
    }
    struct Attrs: Codable {
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

/// The last `/api/home` response, so the page has something to draw before the
/// network answers.
///
/// ## Where it is kept, and why not UserDefaults
///
/// The caches directory, for two reasons. It is the honest place for data that
/// is regenerable by definition and that the system may throw away whenever it
/// likes, which is exactly the contract here - a missing cache costs one blank
/// frame. And it is not included in device backups, whereas UserDefaults is:
/// a lamp's on/off state is about the least sensitive thing ATARU touches, but
/// this app's standing rule is that server responses do not accumulate
/// anywhere (`LiveATARUService` sets `urlCache = nil` on the same grounds), so
/// the copy that does exist should be the narrowest one that solves the
/// problem.
///
/// One file per backend: flipping Settings between the dev twin and production
/// must never show one's devices under the other's name.
private enum HomeCache {

    private struct Envelope: Codable {
        let payload: HomeDTO.Payload
        let savedAt: Date
    }

    /// Derived from the backend URL by substitution, NOT by `hashValue` -
    /// String hashing is seeded per process, so a hashed filename would miss
    /// its own cache on the next launch, which is the only launch that matters.
    private static func fileURL(for root: URL) -> URL? {
        guard let dir = FileManager.default.urls(for: .cachesDirectory,
                                                 in: .userDomainMask).first else { return nil }
        let slug = root.absoluteString.replacingOccurrences(
            of: "[^A-Za-z0-9]", with: "-", options: .regularExpression)
        return dir.appending(path: "home-\(slug).json")
    }

    static func load(for root: URL?) -> (payload: HomeDTO.Payload, savedAt: Date)? {
        guard let root, let url = fileURL(for: root),
              let data = try? Data(contentsOf: url),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data)
        else { return nil }
        return (envelope.payload, envelope.savedAt)
    }

    static func save(_ payload: HomeDTO.Payload, for root: URL) {
        guard let url = fileURL(for: root),
              let data = try? JSONEncoder().encode(
                Envelope(payload: payload, savedAt: Date()))
        else { return }
        try? data.write(to: url, options: .atomic)
    }
}

struct HomeScreen: View {
    @EnvironmentObject private var state: AppState
    @State private var payload: HomeDTO.Payload?
    /// What went wrong last, not merely that something did. See TileFetchError.
    @State private var failure: TileFetchError?
    /// When the payload on screen was fetched, if it came off disk.
    @State private var cachedAt: Date?
    /// Switches the user has flipped that the server has not confirmed yet.
    /// Present means "show this, whatever the payload says".
    @State private var optimistic: [String: Bool] = [:]
    /// One in-flight request per entity, so a rapid re-tap replaces its
    /// predecessor rather than racing it.
    @State private var inFlight: [String: Task<Void, Never>] = [:]
    @State private var toggleNote: String?
    /// Setpoints and modes the user has dialled that the thermostat has not
    /// confirmed yet, and the one deferred request per thermostat that will
    /// carry them. Same optimistic contract as the switches.
    @State private var pendingTarget: [String: Double] = [:]
    @State private var pendingMode: [String: String] = [:]
    @State private var climateTasks: [String: Task<Void, Never>] = [:]

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Space.m) {
                // Three different events, three different things to say.
                //
                // Nothing to show is an error. A refresh that failed over
                // content that is already on screen is NOT - it is a lost
                // round trip, and dressing it as "couldn't reach this surface"
                // is what had the page calling itself unreachable while its
                // own toggles were switching the lights.
                if let failure {
                    if payload == nil {
                        ErrorBanner(message: failure.errorDescription
                                    ?? ScreenState.loadFailed)
                    } else if let cachedAt {
                        FreshnessBanner(state: .stale(cachedAt))
                    } else {
                        InlineNote(text: failure.refreshNote)
                    }
                }
                if let error = payload?.error {
                    ErrorBanner(message: error)
                }
                if let toggleNote { InlineNote(text: toggleNote) }

                // Climate leads: a thermostat is the thing you came to the
                // page to check. Nothing at all when the list is empty or
                // absent - see HomeDTO.Climate.
                if let climate = payload?.climate, !climate.isEmpty {
                    ForEach(climate) { thermostat in
                        climateCard(thermostat)
                    }
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
                                    // No spinner, and no waiting. The switch
                                    // is the user's, not the server's: it
                                    // moves on touch and the request follows.
                                    // It used to be replaced by a ProgressView
                                    // for the whole round trip and then come
                                    // back already in its new position, which
                                    // is why flipping a light felt like
                                    // filing a request and watching it jump.
                                    Toggle("", isOn: Binding(
                                        get: { isOn(device) },
                                        set: { on in flip(device, on: on) }))
                                    .labelsHidden()
                                    .tint(Theme.cyan)
                                }
                                .padding(.vertical, 2)
                            }
                        }
                        .padding(Theme.Space.m)
                    }
                }

                // NO SENSORS CARD. Home Assistant's `sensors` list on this
                // account is sun-cycle entities - next dawn, next dusk, next
                // midnight - rendered as raw timestamps. Nothing on that card
                // was ever worth the scroll, and none of it is actionable
                // from a phone. The server still sends the list; the app
                // ignores it, which is why the DTO no longer decodes it.
            }
            .padding(Theme.Space.screen)
        }
        .ataruBackdrop()
        .navigationTitle("Home")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task {
            // Draw the last known state first, then go and check it. The page
            // used to sit completely blank for the whole round trip - nothing
            // renders until `payload` is non-nil - which on a tailnet round
            // trip to the mini is exactly the "takes a moment" he reported.
            if payload == nil, let cached = HomeCache.load(for: root) {
                payload = cached.payload
                cachedAt = cached.savedAt
            }
            await load()
        }
    }

    private var root: URL? { TileBackend.current(from: state).apiRoot(.home) }

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

    @discardableResult
    private func load() async -> Bool {
        guard let root else { return false }
        // No loading state of any kind. A refresh over content that is
        // already on screen must be invisible until it has something to say -
        // see the note on ScreenState.
        do {
            // Longer than the shared default. This endpoint gathers the whole
            // of Home Assistant's state, where /api/toggle touches one entity
            // - the asymmetry that had a page timing out on refresh while its
            // own toggles answered instantly. It costs nothing to wait now
            // that the page renders from cache instead of sitting blank.
            let fresh = try await TileFetch.get(
                HomeDTO.Payload.self, root.appending(path: "api/home"), timeout: 25)
            withAnimation(.easeOut(duration: 0.2)) {
                payload = fresh
                failure = nil
                cachedAt = nil
            }
            HomeCache.save(fresh, for: root)
            return true
        } catch {
            withAnimation(.easeOut(duration: 0.2)) {
                failure = error as? TileFetchError ?? .unreachable
            }
            return false
        }
    }

    // MARK: - Thermostat

    private static let modes: [(id: String, label: String, symbol: String)] = [
        ("heat", "Heat", "flame"),
        ("cool", "Cool", "snowflake"),
        ("heat_cool", "Auto", "arrow.up.arrow.down"),
        ("off", "Off", "power"),
    ]

    @ViewBuilder
    private func climateCard(_ thermostat: HomeDTO.Climate) -> some View {
        let entity = thermostat.entity_id ?? ""
        let mode = pendingMode[entity] ?? thermostat.hvac_mode ?? "off"
        let target = pendingTarget[entity] ?? thermostat.target_temp

        ATCard {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                SectionHeader(text: thermostat.name ?? "Thermostat")

                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                    // The number you actually came to read.
                    Text(Self.degrees(thermostat.current_temp))
                        .font(.system(size: 44, weight: .thin))
                        .foregroundStyle(Theme.textPrimary)
                        .monospacedDigit()
                    VStack(alignment: .leading, spacing: 1) {
                        if let action = thermostat.hvac_action, !action.isEmpty {
                            Text(action.capitalized)
                                .font(.ataruCaption())
                                .foregroundStyle(action == "idle" ? Theme.textTertiary : Theme.cyan)
                        }
                        if let humidity = thermostat.humidity {
                            Text("\(Int(humidity))% humidity")
                                .font(.ataruCaption())
                                .foregroundStyle(Theme.textTertiary)
                        }
                    }
                    Spacer(minLength: 0)
                }

                if thermostat.isRange {
                    // A band, and the POST contract has one `temperature`
                    // field - so this is shown and not offered for editing
                    // rather than pretending a stepper could set it.
                    HStack {
                        Text("Target")
                            .font(.ataruCaption())
                            .foregroundStyle(Theme.textTertiary)
                        Spacer()
                        Text("\(Self.degrees(thermostat.target_temp_low)) – \(Self.degrees(thermostat.target_temp_high))")
                            .font(.ataruBody())
                            .foregroundStyle(Theme.textPrimary)
                            .monospacedDigit()
                    }
                } else if mode != "off" {
                    HStack(spacing: Theme.Space.m) {
                        Text("Target")
                            .font(.ataruCaption())
                            .foregroundStyle(Theme.textTertiary)
                        Spacer(minLength: 0)
                        stepButton("minus", entity: entity) { step(thermostat, by: -1) }
                        Text(Self.degrees(target))
                            .font(.system(size: 22, weight: .light))
                            .foregroundStyle(Theme.cyan)
                            .monospacedDigit()
                            .frame(minWidth: 62)
                            .contentTransition(.numericText())
                        stepButton("plus", entity: entity) { step(thermostat, by: 1) }
                    }
                }

                HStack(spacing: Theme.Space.xs) {
                    ForEach(Self.modes, id: \.id) { option in
                        modeChip(option, selected: mode == option.id) {
                            setMode(thermostat, to: option.id)
                        }
                    }
                }
            }
            .padding(Theme.Space.m)
        }
    }

    private func stepButton(_ symbol: String, entity: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.cyan)
                .frame(width: 38, height: 38)
                .background {
                    Circle().fill(Theme.surfaceElevated)
                }
        }
        .buttonStyle(.atPress)
    }

    private func modeChip(_ option: (id: String, label: String, symbol: String),
                          selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: option.symbol).font(.system(size: 11))
                Text(option.label).font(.ataruCaption())
            }
            .padding(.horizontal, Theme.Space.s)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background {
                RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                    .fill(selected ? Theme.cyan.opacity(0.16) : Theme.surfaceElevated)
            }
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                    .strokeBorder(selected ? Theme.cyan : .clear, lineWidth: 1)
            }
            .foregroundStyle(selected ? Theme.cyan : Theme.textTertiary)
        }
        .buttonStyle(.atPress)
    }

    private static func degrees(_ value: Double?) -> String {
        guard let value else { return "--°" }
        // No unit assumed. The server reports whatever Home Assistant is set
        // to, and printing an F onto a C reading would be worse than silence.
        return value == value.rounded() ? "\(Int(value))°"
                                        : String(format: "%.1f°", value)
    }

    /// A stepper tap moves the number NOW, and the request is deferred.
    ///
    /// Coalescing, not just debouncing: holding + through six degrees sends
    /// ONE setpoint, not six. Each tap cancels the pending send and restarts
    /// the wait, so the thermostat is asked for the number he stopped on -
    /// which also means a burst never arrives out of order.
    private func step(_ thermostat: HomeDTO.Climate, by delta: Double) {
        guard let entity = thermostat.entity_id else { return }
        let base = pendingTarget[entity] ?? thermostat.target_temp ?? 70
        let next = min(90, max(45, (base + delta).rounded()))
        guard next != base else { return }
        Haptics.fire(.selection)
        withAnimation(.spring(response: 0.26, dampingFraction: 0.82)) {
            pendingTarget[entity] = next
            toggleNote = nil
        }
        climateTasks[entity]?.cancel()
        climateTasks[entity] = Task { await commitClimate(entity, temperature: next, mode: nil) }
    }

    private func setMode(_ thermostat: HomeDTO.Climate, to mode: String) {
        guard let entity = thermostat.entity_id,
              (pendingMode[entity] ?? thermostat.hvac_mode) != mode else { return }
        Haptics.fire(.selection)
        withAnimation(.spring(response: 0.26, dampingFraction: 0.82)) {
            pendingMode[entity] = mode
            toggleNote = nil
        }
        climateTasks[entity]?.cancel()
        // No wait: a mode is one deliberate tap, not a run of them.
        climateTasks[entity] = Task { await commitClimate(entity, temperature: nil, mode: mode) }
    }

    private func commitClimate(_ entity: String, temperature: Double?, mode: String?) async {
        if temperature != nil {
            // The coalescing window. Cancelled by the next tap.
            try? await Task.sleep(for: .milliseconds(650))
            guard !Task.isCancelled else { return }
        }
        guard let root else { return }
        do {
            let reply = try await TileFetch.post(
                HomeDTO.ClimateReply.self, root.appending(path: "api/climate"),
                body: HomeDTO.ClimateBody(entity_id: entity, temperature: temperature,
                                          hvac_mode: mode))
            if Task.isCancelled { return }
            if let error = reply.error {
                revertClimate(entity, note: error)
                return
            }
            // Silent reconcile. The verified object when the server nests one,
            // otherwise a plain refresh - and if THAT fails the optimistic
            // value stays, because the setpoint is known to have landed.
            if reply.climate != nil {
                await load()
            } else if await load() == false {
                return
            }
            guard !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.26, dampingFraction: 0.82)) {
                pendingTarget[entity] = nil
                pendingMode[entity] = nil
            }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            revertClimate(entity, note: (error as? TileFetchError)?.refreshNote
                          ?? "That didn't reach the thermostat.")
        }
    }

    private func revertClimate(_ entity: String, note: String) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            pendingTarget[entity] = nil
            pendingMode[entity] = nil
            toggleNote = note
        }
    }

    // MARK: - Switches

    /// What the switch shows: the user's intent while one is outstanding, the
    /// server's answer otherwise.
    private func isOn(_ device: HomeDTO.Device) -> Bool {
        if let entity = device.entity_id, let pending = optimistic[entity] {
            return pending
        }
        return device.state == "on"
    }

    private func flip(_ device: HomeDTO.Device, on: Bool) {
        guard let entity = device.entity_id else { return }
        Haptics.fire(.selection)
        withAnimation(.spring(response: 0.26, dampingFraction: 0.82)) {
            optimistic[entity] = on
            toggleNote = nil
        }
        // Last intent wins. Flipping twice quickly cancels the first request
        // rather than letting two answers arrive in whatever order they like
        // and settling on the older one.
        inFlight[entity]?.cancel()
        inFlight[entity] = Task { await send(entity, on: on) }
    }

    private func send(_ entity: String, on: Bool) async {
        guard let root else { return }
        do {
            let reply = try await TileFetch.post(
                HomeDTO.ToggleReply.self, root.appending(path: "api/toggle"),
                body: HomeDTO.ToggleBody(entity_id: entity, action: on ? "on" : "off"))
            if Task.isCancelled { return }
            if let error = reply.error {
                revert(entity, note: error)
                return
            }
            // The switch already shows the right thing, so this refresh is
            // only about the rest of the card - brightness, power draw. If it
            // fails, the optimistic value STAYS: the toggle is known to have
            // worked, and snapping the switch back because a separate request
            // did not answer would be a lie in the other direction.
            let refreshed = await load()
            guard !Task.isCancelled, refreshed else { return }
            withAnimation(.spring(response: 0.26, dampingFraction: 0.82)) {
                optimistic[entity] = nil
            }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            revert(entity, note: (error as? TileFetchError)?.refreshNote
                   ?? "That didn't reach the device.")
        }
    }

    /// Put the switch back where it was, and say so on one line. Deliberately
    /// not an alert: a light that did not turn on is not worth a modal.
    private func revert(_ entity: String, note: String) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            optimistic[entity] = nil
            toggleNote = note
        }
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
                    .buttonStyle(.atPress)
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
                    .buttonStyle(.atPress)
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
