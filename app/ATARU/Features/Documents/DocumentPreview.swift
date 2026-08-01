import QuickLook
import SwiftUI
import UIKit

/// Quick Look, wrapped for SwiftUI.
///
/// Quick Look is used rather than a hand-rolled viewer per file type because
/// it already renders PDFs, images, video, text and Office formats correctly,
/// including selection and accessibility. Anything it can't render shows its
/// own explanatory state, which is better than the app guessing.
struct QuickLookView: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        context.coordinator.url = url
        controller.reloadData()
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL
        init(url: URL) { self.url = url }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController,
                               previewItemAt index: Int) -> QLPreviewItem {
            url as QLPreviewItem
        }
    }
}

/// The system share sheet.
///
/// Sharing is always an explicit user action — there is no automatic upload,
/// no "share to" shortcut, and no default recipient. What leaves the phone,
/// and to whom, is chosen in this sheet by the person who owns the files.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items,
                                                  applicationActivities: nil)
        // These would put vault content somewhere the user did not intend.
        controller.excludedActivityTypes = [
            .assignToContact,
            .addToReadingList,
            .openInIBooks
        ]
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
