import PDFKit
import SwiftUI
import UIKit

/// One file, open.
///
/// Four renderers rather than QuickLook for everything, which is what the
/// vault library does. The reason is the toolbar: a `QLPreviewController`
/// owns its own chrome and its own navigation bar, so "Show on display" and
/// the NAS state have nowhere to live inside one. PDFs, images and text are
/// rendered directly - they are the overwhelming majority of the index and
/// PDFKit paginates better than Quick Look does inside a sheet - and Office
/// formats, which nothing on iOS renders natively, still go to Quick Look.
struct FileViewerScreen: View {
    let id: String
    /// What to call it before the server has been asked. The detail response
    /// replaces this the moment it lands.
    let fallbackTitle: String
    let service: ATARUService

    @State private var detail: FileDetail?
    @State private var payload: DocumentPayload?
    @State private var failure: String?
    @State private var isSharing = false
    @State private var displayMessage: String?
    @State private var isSendingToDisplay = false

    init(id: String, fallbackTitle: String, service: ATARUService) {
        self.id = id
        self.fallbackTitle = fallbackTitle
        self.service = service
    }

    init(hit: FileHit, service: ATARUService) {
        self.init(id: hit.id, fallbackTitle: hit.name, service: service)
    }

    private var title: String { detail?.file.name ?? fallbackTitle }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ataruBackdrop()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    displayButton
                    shareButton
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let displayMessage {
                    DockedOrbCaption(text: displayMessage) {
                        self.displayMessage = nil
                    }
                    .padding(.horizontal, Theme.Space.screen)
                    .padding(.bottom, Theme.Space.xs)
                }
            }
            .sheet(isPresented: $isSharing) {
                if let payload { ShareSheet(items: [payload.url]) }
            }
            .task(id: id) { await load() }
    }

    // MARK: - Body

    @ViewBuilder
    private var content: some View {
        if let failure {
            ATStateView(symbol: "doc.questionmark", title: "Couldn't open it",
                        message: failure, tone: Theme.amber) {
                Task { await load(force: true) }
            }
        } else if let detail, detail.file.location.isAway {
            away(detail.file)
        } else if let detail, detail.viewer == .none || !detail.previewable {
            ATStateView(symbol: detail.file.kind.symbol,
                        title: "Nothing to show",
                        message: "ATARU has this file indexed, but there is no viewer "
                            + "on the phone for a \(detail.file.ext.uppercased()). "
                            + "Share it to open it in another app.")
        } else if let payload, let detail {
            viewer(for: detail, payload: payload)
        } else {
            ProgressView("Opening \(title)…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .tint(Theme.cyan)
        }
    }

    @ViewBuilder
    private func viewer(for detail: FileDetail, payload: DocumentPayload) -> some View {
        switch detail.viewer {
        case .pdf:
            PDFDocumentView(url: payload.url)
        case .image:
            ZoomableImage(url: payload.url)
        case .text:
            textViewer(payload.url)
        case .office:
            // docx, pptx, xlsx. Nothing on iOS draws these; Quick Look does,
            // and it already handles selection, paging and accessibility.
            QuickLookView(url: payload.url)
        case .none:
            EmptyView()
        }
    }

    /// Markdown and plain text, read as prose.
    ///
    /// Deliberately NOT monospaced. The index is mostly notes, drafts and
    /// chapters rather than code, and a proportional face is what those were
    /// written to be read in.
    @ViewBuilder
    private func textViewer(_ url: URL) -> some View {
        ScrollView {
            Text(Self.text(at: url))
                .font(.ataruBody())
                .foregroundStyle(Theme.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Theme.Space.screen)
        }
    }

    private func away(_ hit: FileHit) -> some View {
        VStack(spacing: Theme.Space.s) {
            ATStateView(
                symbol: "externaldrive.badge.icloud",
                title: "Not on this host yet",
                message: "\(hit.name) lives on the NAS. ATARU knows it is there and "
                    + "can find it by name, but the bytes are not on the machine "
                    + "this app talks to, so there is nothing to open.",
                tone: Theme.amber)
            Text(hit.path)
                .font(.ataruMono(11))
                .foregroundStyle(Theme.textTertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Theme.Space.screen)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Toolbar

    @ViewBuilder
    private var shareButton: some View {
        Button { isSharing = true } label: {
            Image(systemName: "square.and.arrow.up")
        }
        .disabled(payload == nil)
        .accessibilityLabel("Share this file")
    }

    /// Puts the file on the mini's kiosk display.
    ///
    /// THERE IS NO REST ROUTE FOR THIS. The server's document-on-display path
    /// is a chat shortcut, so the app asks in words - see
    /// `ATARUService.showOnDisplay`. What comes back is the server's own
    /// sentence, including the two cases where it found the file and could not
    /// show it, and that sentence is what is shown here rather than a "sent"
    /// this screen has no way to verify.
    @ViewBuilder
    private var displayButton: some View {
        Button {
            guard !isSendingToDisplay else { return }
            isSendingToDisplay = true
            let name = detail?.file.title ?? fallbackTitle
            Task {
                do {
                    displayMessage = try await service.showOnDisplay(title: name)
                } catch {
                    displayMessage = "Couldn't reach the display: "
                        + ((error as? APIError)?.localizedDescription
                           ?? error.localizedDescription)
                }
                isSendingToDisplay = false
            }
        } label: {
            if isSendingToDisplay {
                ProgressView().tint(Theme.cyan)
            } else {
                Image(systemName: "tv")
            }
        }
        .disabled(detail?.file.location.isAway ?? false)
        .accessibilityLabel("Show on the display")
        .accessibilityHint("Asks ATARU to put this file on the wall display.")
    }

    // MARK: - Loading

    private func load(force: Bool = false) async {
        if !force, detail != nil, payload != nil { return }
        failure = nil
        do {
            let found = try await service.fileDetail(id: id)
            detail = found
            // An away file has no bytes here; asking for them would 404 and
            // the honest state is already on screen.
            guard !found.file.location.isAway, found.previewable,
                  found.viewer != .none else { return }
            payload = try await service.fileContent(id: id)
        } catch {
            failure = (error as? APIError)?.localizedDescription
                ?? error.localizedDescription
        }
    }

    /// Read on the main actor because it is a small local file that has
    /// already been written to disk; anything the index calls text is a few
    /// hundred kilobytes at most.
    private static func text(at url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8))
            ?? (try? String(contentsOf: url, encoding: .isoLatin1))
            ?? "This file is not text after all."
    }
}

// MARK: - The two native renderers

/// PDFKit, wrapped.
///
/// Continuous vertical scrolling with `autoScales`, which is what makes a
/// letter-sized page fit a phone without pinching first.
struct PDFDocumentView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = .clear
        view.document = PDFDocument(url: url)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        if view.document?.documentURL != url {
            view.document = PDFDocument(url: url)
        }
    }
}

/// An image that pinches and pans, which `Image` alone does not.
struct ZoomableImage: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView()
        scroll.delegate = context.coordinator
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 6
        scroll.backgroundColor = .clear
        scroll.showsVerticalScrollIndicator = false
        scroll.showsHorizontalScrollIndicator = false

        let image = UIImageView(image: (try? Data(contentsOf: url)).flatMap(UIImage.init))
        image.contentMode = .scaleAspectFit
        image.frame = scroll.bounds
        image.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scroll.addSubview(image)
        context.coordinator.imageView = image
        return scroll
    }

    func updateUIView(_ view: UIScrollView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var imageView: UIImageView?
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
    }
}

// MARK: - Presenting one by reference

/// The sheet an answer's `document` payload opens.
///
/// WHICH VIEWER DEPENDS ON WHICH INDEX. A vault record resolves through
/// `/documents/{id}` and a projects file through `/api/files/{id}`; the ids are
/// server-assigned hashes of different things and are not interchangeable, so
/// sending one to the other's route is a 404 with nothing on screen to explain
/// it. `DocumentRef.source` is what keeps them apart.
struct DocumentRefViewer: View {
    let document: DocumentRef
    let service: ATARUService

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        switch document.source {
        case .vault:
            DocumentPopup(document: document, service: service)
        case .files:
            NavigationStack {
                FileViewerScreen(id: document.id, fallbackTitle: document.title,
                                 service: service)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Done") { dismiss() }
                        }
                    }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }
}
