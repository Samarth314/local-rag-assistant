import SwiftUI

/// One document: what it is, where it came from, and what you can do with it.
///
/// Content is **not** fetched on appear. Opening a card shows metadata the
/// library already has; the bytes only leave the vault when the user asks for
/// them by tapping Preview or Send. That is the difference between browsing an
/// index and copying private files onto a phone, and it should be a decision
/// the user makes rather than a side effect of scrolling.
struct DocumentDetailView: View {
    let document: IndexedDocument

    @EnvironmentObject private var state: AppState
    @StateObject private var model = DocumentContentModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                header
                actions
                if let payload = model.payload, payload.isReconstructed {
                    reconstructedNotice
                }
                if case .failed(let message) = model.state {
                    ATStateView(symbol: "exclamationmark.triangle", title: "Couldn't fetch the file",
                                message: message, tone: Theme.amber) {
                        model.load(document: document, service: state.service)
                    }
                }
                metadata
            }
            .padding(Theme.Space.screen)
        }
        .ataruBackdrop()
        .navigationTitle(document.title)
        .navigationBarTitleDisplayMode(.inline)
        // Both sheets hand the file's URL to something outside this view - and
        // AirDrop, Save to Files and Mail all background the app while the
        // receiver is still reading it, which is exactly when the download
        // store used to delete it. Held for as long as the sheet is up.
        .sheet(isPresented: $model.isPreviewing,
               onDismiss: { model.finishedPresenting() }) {
            if let payload = model.payload {
                QuickLookView(url: payload.url)
                    .ignoresSafeArea()
            }
        }
        .sheet(isPresented: $model.isSharing,
               onDismiss: { model.finishedPresenting() }) {
            if let payload = model.payload {
                ShareSheet(items: [payload.url])
                    .presentationDetents([.medium, .large])
            }
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.xs) {
                ATPill(text: document.category.title, tone: Theme.cyan)
                if !document.fileType.isEmpty {
                    ATPill(text: document.fileType, tone: Theme.textSecondary)
                }
                Spacer(minLength: 0)
            }
            Text(document.title)
                .font(.ataruTitle())
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if !document.excerpt.isEmpty {
                Text(document.excerpt)
                    .font(.ataruBody())
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var actions: some View {
        HStack(spacing: Theme.Space.s) {
            ActionButton(
                title: document.previewable ? "Preview" : "Open as text",
                symbol: "eye",
                isBusy: model.state == .loading && model.intent == .preview
            ) {
                model.load(document: document, service: state.service, then: .preview)
            }

            ActionButton(title: "Send", symbol: "square.and.arrow.up",
                         isBusy: model.state == .loading && model.intent == .share) {
                model.load(document: document, service: state.service, then: .share)
            }
        }
        .disabled(model.state == .loading)
    }

    private var reconstructedNotice: some View {
        HStack(alignment: .top, spacing: Theme.Space.xs) {
            Image(systemName: "info.circle")
                .font(.system(size: 12, weight: .semibold))
            // Stated plainly because the user is about to send this to someone
            // else, and what they are sending is not the original file.
            Text("The original file wasn't reachable, so this is the text ATARU extracted when it indexed it — not the source document.")
                .font(.ataruCaption())
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Theme.amber)
        .padding(Theme.Space.s)
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                .fill(Theme.amber.opacity(0.10))
        }
        .accessibilityElement(children: .combine)
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            SectionLabel(text: "Details")
            ATCard {
                VStack(spacing: 0) {
                    MetadataRow(label: "Category", value: document.category.title)
                    if let size = document.sizeBytes {
                        MetadataRow(label: "Size", value: MetricFormatter.bytes(size))
                    }
                    MetadataRow(label: "Modified", value: document.modifiedAt
                        .map { DateFormatting.medium($0) } ?? "Unknown")
                    MetadataRow(label: "Indexed", value: document.indexedAt
                        .map { RelativeTime.compact(for: $0) } ?? "Before ATARU recorded it")
                    if let chunks = document.chunkCount {
                        MetadataRow(label: "Chunks", value: "\(chunks)")
                    }
                    MetadataRow(label: "Vault path", value: document.path, isPath: true)
                }
                .padding(.vertical, Theme.Space.xxs)
            }
            if !document.tags.isEmpty {
                HStack(spacing: Theme.Space.xs) {
                    ForEach(document.tags, id: \.self) { ATPill(text: $0) }
                }
            }
        }
    }
}

private struct MetadataRow: View {
    let label: String
    let value: String
    var isPath: Bool = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
            Text(label)
                .font(.ataruCaption())
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 88, alignment: .leading)
            Text(value)
                .font(isPath ? .ataruMono(12) : .ataruCaption())
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.xs)
        .accessibilityElement(children: .combine)
    }
}

private struct ActionButton: View {
    let title: String
    let symbol: String
    var isBusy: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.xs) {
                if isBusy {
                    ProgressView().controlSize(.small).tint(Theme.cyan)
                } else {
                    Image(systemName: symbol).font(.system(size: 13))
                }
                Text(title).font(.ataruCaption())
            }
            .foregroundStyle(Theme.textPrimary)
            .frame(maxWidth: .infinity, minHeight: Theme.minHitTarget)
            .background {
                RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                    .fill(Theme.surface)
            }
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                    .strokeBorder(Theme.border, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }
}

/// Fetches document bytes on demand, once, for a specific purpose.
@MainActor
final class DocumentContentModel: ObservableObject {
    enum Intent { case preview, share }
    enum State: Equatable { case idle, loading, ready, failed(String) }

    @Published private(set) var state: State = .idle
    @Published private(set) var payload: DocumentPayload?
    @Published private(set) var intent: Intent?
    @Published var isPreviewing = false
    @Published var isSharing = false

    private var task: Task<Void, Never>?
    /// The URL currently held open by a sheet, if any.
    private var presentedURL: URL?

    func load(document: IndexedDocument, service: ATARUService, then intent: Intent = .preview) {
        // Already downloaded in this session: don't fetch the file twice just
        // because the user previewed it before sharing it.
        if let payload, state == .ready {
            present(intent, payload: payload)
            return
        }
        task?.cancel()
        self.intent = intent
        state = .loading
        task = Task {
            do {
                let result = try await service.documentContent(id: document.id)
                guard !Task.isCancelled else { return }
                payload = result
                state = .ready
                present(intent, payload: result)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                state = .failed((error as? APIError)?.localizedDescription
                                ?? error.localizedDescription)
            }
        }
    }

    private func present(_ intent: Intent, payload: DocumentPayload) {
        // Retained before the sheet goes up, released when it comes down. A
        // share sheet is the app handing a file path to another process; the
        // file has to outlive this app leaving the foreground.
        Task { await DocumentDownloadStore.shared.retain(payload.url) }
        presentedURL = payload.url
        switch intent {
        case .preview: isPreviewing = true
        case .share: isSharing = true
        }
        Haptics.fire(.tap)
    }

    /// Called from both sheets' `onDismiss`.
    func finishedPresenting() {
        guard let url = presentedURL else { return }
        presentedURL = nil
        Task { await DocumentDownloadStore.shared.release(url) }
    }
}

#Preview {
    NavigationStack {
        DocumentDetailView(document: DemoFixtures.documents()[3])
            .environmentObject(AppState())
    }
}
