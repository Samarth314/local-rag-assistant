import SwiftUI
import UniformTypeIdentifiers

/// The monthly statement checklist: page three of Finance.
///
/// The job it exists for is one morning a month. Six accounts, some of which
/// have posted and some of which have not, and the question is only ever which
/// ones still need collecting - so the rows sort by what needs doing and the
/// login button sits on the row rather than in a menu.
///
/// Nothing on this page claims more than the server told it. An upload lands a
/// file in the inbox; the row does not turn green until the vault has actually
/// ingested it, which is a separate thing that happens seconds later. See
/// `StatementsModel.upload`.
struct StatementsPage: View {
    @ObservedObject var model: StatementsModel
    @Environment(\.openURL) private var openURL

    @State private var isPicking = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                if model.failed {
                    if model.payload == nil {
                        ErrorBanner(message: ScreenState.loadFailed)
                    } else if let cachedAt = model.cachedAt {
                        FreshnessBanner(state: .stale(cachedAt))
                    } else {
                        InlineNote(text: "Couldn't refresh - this is the last ATARU had.")
                    }
                }

                if let payload = model.payload {
                    if payload.showsNudge { nudge(payload) }
                    header(payload)

                    if payload.storeIsBroken {
                        // The store could not be read, so every row below it
                        // would be a guess. What is still true is where to go
                        // and look, so that is all this shows.
                        storeBroken(payload)
                        loginsOnly
                    } else {
                        checklist(payload)
                        uploadSection
                    }
                } else if !model.failed {
                    ProgressView()
                        .tint(Theme.cyan)
                        .frame(maxWidth: .infinity)
                        .padding(.top, Theme.Space.xl)
                }
            }
            .padding(Theme.Space.screen)
        }
        .refreshable { await model.load() }
        .fileImporter(isPresented: $isPicking,
                      allowedContentTypes: [.pdf, .commaSeparatedText],
                      allowsMultipleSelection: true) { result in
            guard case .success(let picked) = result else { return }
            Task { await model.upload(picked) }
        }
        .onDisappear { model.cancelPolling() }
    }

    // MARK: - Nudge

    /// Prominent, and deliberately not alarming.
    ///
    /// It appears on one day a month and it is a to-do, not a fault: the
    /// wording is what has to be done rather than what has gone wrong, and it
    /// borrows the accent rather than the warning colour.
    private func nudge(_ payload: StatementsDTO) -> some View {
        let count = payload.missingCount
        let month = payload.sittingMonthName
        return ATCard {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: "tray.and.arrow.down")
                    .font(.system(size: 18, weight: .light))
                    .foregroundStyle(Theme.cyan)
                VStack(alignment: .leading, spacing: 2) {
                    Text(month.map { "\(count) statement\(count == 1 ? "" : "s") to collect for \($0)" }
                         ?? "\(count) statement\(count == 1 ? "" : "s") to collect")
                        .font(.ataruBody())
                        .foregroundStyle(Theme.textPrimary)
                    Text("Log in below, or send them up from this phone.")
                        .font(.ataruCaption())
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer(minLength: 0)
            }
            .padding(Theme.Space.m)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Header

    private func header(_ payload: StatementsDTO) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xxs) {
            SectionLabel(text: payload.sitting?.label ?? "Statement sitting")
            HStack(spacing: Theme.Space.xs) {
                if let date = payload.sitting?.date {
                    Text(date)
                        .font(.ataruMono(13))
                        .foregroundStyle(Theme.textSecondary)
                }
                Text(payload.stateLine)
                    .font(.ataruBody())
                    .foregroundStyle(payload.missingCount > 0
                                     ? Theme.amber : Theme.textPrimary)
            }
            // One line, and only while it is still actionable. See
            // `StatementsDTO.requestLine(today:)` for the rule.
            if let request = payload.requestLine(today: StatementsDTO.todayISO()) {
                Text(request)
                    .font(.ataruCaption())
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            if let asOf = payload.as_of {
                Text("Checked \(asOf)")
                    .font(.ataruCaption())
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func storeBroken(_ payload: StatementsDTO) -> some View {
        ATCard {
            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                Label("The statement store could not be read",
                      systemImage: "exclamationmark.triangle")
                    .font(.ataruBody())
                    .foregroundStyle(Theme.amber)
                Text(payload.store?.reason ?? "The server did not say why.")
                    .font(.ataruCaption())
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("The checklist is hidden rather than shown wrong. The logins still work.")
                    .font(.ataruCaption())
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Space.m)
        }
    }

    /// Every login, from the app's own table rather than from the payload:
    /// this is the branch where the payload is what went wrong.
    private var loginsOnly: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            SectionHeader(text: "Log in")
            ForEach(StatementLogin.catalog) { known in
                Button { openURL(known.url) } label: {
                    HStack {
                        Text(known.label)
                            .font(.ataruBody())
                            .foregroundStyle(Theme.textPrimary)
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.cyan)
                    }
                    .padding(.vertical, Theme.Space.xs)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Log in to \(known.label)")
            }
        }
    }

    // MARK: - Checklist

    private func checklist(_ payload: StatementsDTO) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            SectionHeader(text: "Accounts")
            // By POSITION, like every other list on these screens: `id` is
            // optional in the payload, and two rows that arrive without one
            // are the same id and so draw as a single row.
            ForEach(Array(payload.orderedSources.enumerated()), id: \.offset) { _, source in
                StatementRow(source: source) { url in openURL(url) }
            }
        }
    }

    // MARK: - Upload

    private var uploadSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            SectionHeader(text: "Send from this phone")

            Button { isPicking = true } label: {
                HStack(spacing: Theme.Space.xs) {
                    if model.isUploading {
                        ProgressView().tint(Theme.cyan)
                    } else {
                        Image(systemName: "arrow.up.doc")
                    }
                    Text(model.isUploading ? "Uploading…" : "Upload a statement")
                }
                .font(.ataruLabel())
                .foregroundStyle(Theme.cyan)
                .padding(.vertical, Theme.Space.xs)
                .padding(.horizontal, Theme.Space.s)
                .background {
                    Capsule().fill(Theme.accentSoft)
                }
                .overlay { Capsule().strokeBorder(Theme.cyanSubdued, lineWidth: 1) }
            }
            .buttonStyle(.plain)
            .disabled(model.isUploading)
            .accessibilityLabel("Upload a statement")
            .accessibilityHint("Picks PDF or CSV files and sends them to the vault inbox.")

            Text("PDF or CSV. They land in the vault inbox and are filed there.")
                .font(.ataruCaption())
                .foregroundStyle(Theme.textTertiary)

            if let failure = model.uploadFailure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .font(.ataruCaption())
                    .foregroundStyle(Theme.amber)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let result = model.lastUpload { uploadResult(result) }
        }
    }

    private func uploadResult(_ result: StatementsUploadDTO) -> some View {
        ATCard {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                ForEach(Array((result.accepted ?? []).enumerated()), id: \.offset) { _, file in
                    resultRow(symbol: "checkmark.circle",
                              tone: Theme.green,
                              name: file.name ?? "File",
                              detail: file.bytes.map { "\($0) bytes, in the inbox" }
                                      ?? "In the inbox")
                }
                ForEach(Array((result.rejected ?? []).enumerated()), id: \.offset) { _, file in
                    resultRow(symbol: "xmark.circle",
                              tone: Theme.amber,
                              name: file.name ?? "File",
                              detail: file.reason ?? "Rejected")
                }
                if model.isIngesting {
                    Text("Ingesting - the checklist updates itself.")
                        .font(.ataruCaption())
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.top, Theme.Space.xxs)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Space.m)
        }
    }

    private func resultRow(symbol: String, tone: Color,
                           name: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.xs) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(tone)
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.ataruBody())
                    .foregroundStyle(Theme.textPrimary)
                Text(detail)
                    .font(.ataruCaption())
                    .foregroundStyle(Theme.textTertiary)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - One account

private struct StatementRow: View {
    let source: StatementsDTO.Source
    let login: (URL) -> Void

    var body: some View {
        ATCard {
            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.xs) {
                    // Symbol AND word, never the tint alone.
                    Image(systemName: source.state.symbol)
                        .font(.system(size: 13))
                        .foregroundStyle(tone)
                    Text(source.displayLabel)
                        .font(.ataruBody())
                        .foregroundStyle(Theme.textPrimary)
                    Spacer(minLength: 0)
                    Text(source.state.word)
                        .font(.ataruCaption())
                        .foregroundStyle(tone)
                }

                Text(detail)
                    .font(.ataruCaption())
                    .foregroundStyle(Theme.textTertiary)

                // How this one is asked for, when asking is a step of its own.
                // The same secondary style as the meta line above it, and
                // deliberately not the amber of a fault: it is guidance for a
                // row that still needs collecting, not something gone wrong.
                if let note = source.visibleRequestNote {
                    Text(note)
                        .font(.ataruCaption())
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let gaps = source.gaps, !gaps.isEmpty {
                    Text("Also missing: \(gaps.joined(separator: ", "))")
                        .font(.ataruCaption())
                        .foregroundStyle(Theme.amber)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let url = StatementLogin.url(for: source) {
                    Button { login(url) } label: {
                        HStack(spacing: 4) {
                            Text("Log in")
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .font(.ataruLabel())
                        .foregroundStyle(Theme.cyan)
                        .padding(.top, Theme.Space.xxs)
                        .hitTarget()
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Log in to \(source.displayLabel)")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Space.m)
        }
    }

    private var tone: Color {
        switch source.state {
        case .present:        return Theme.green
        case .missing:        return Theme.amber
        case .not_posted_yet: return Theme.textSecondary
        case .unknown:        return Theme.textTertiary
        }
    }

    private var detail: String {
        var bits: [String] = []
        if let month = source.target_month { bits.append("For \(month)") }
        bits.append(source.latest_period_end.map { "latest \($0)" }
                    ?? "nothing filed yet")
        return bits.joined(separator: " · ")
    }
}
