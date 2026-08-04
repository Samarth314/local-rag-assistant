import SwiftUI

/// The file a pull-up turn opened, over whatever was on screen.
///
/// Arya asked for "a pop up I can see the file in, zoom in and out and scroll
/// through, and then minimize and it'll show it". QuickLook already gives
/// pinch-zoom, scrolling and paging for PDFs, images, text and Office formats,
/// so the work here is fetching the bytes and presenting them - not rendering.
///
/// A `.sheet` with detents rather than a full-screen cover, because "minimize"
/// is the point: dragging it down to `.medium` leaves the answer visible
/// underneath, and the grabber makes that discoverable without a button. The
/// answer card keeps its own way back in, so dismissing loses nothing.
struct DocumentPopup: View {
    let document: DocumentRef
    let service: ATARUService

    @State private var payload: DocumentPayload?
    @State private var failure: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let payload {
                    QuickLookView(url: payload.url)
                } else if let failure {
                    ContentUnavailableView(
                        "Couldn't open it", systemImage: "doc.questionmark",
                        description: Text(failure))
                } else {
                    ProgressView("Fetching \(document.title)…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .ataruBackdrop()
            .navigationTitle(document.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        // Medium first: he asked for it, and it lands as "on screen but not
        // in the way" rather than taking the whole display for a one-page PDF.
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task(id: document.id) { await load() }
    }

    private func load() async {
        payload = nil
        failure = nil
        do {
            payload = try await service.documentContent(id: document.id)
        } catch {
            // Say what happened. The document is on the wall display either
            // way, so this is a degraded path, not a dead end.
            failure = (error as? APIError)?.localizedDescription
                ?? error.localizedDescription
        }
    }
}
