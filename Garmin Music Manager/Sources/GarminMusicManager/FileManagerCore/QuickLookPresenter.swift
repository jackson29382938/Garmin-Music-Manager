import AppKit
import Foundation
import Quartz

/// Presents Quick Look for local file URLs.
@MainActor
enum QuickLookPresenter {
    static func preview(urls: [URL]) {
        guard !urls.isEmpty else { return }
        QuickLookController.shared.preview(urls: urls)
    }
}

final class QuickLookController: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLookController()

    private var urls: [URL] = []

    @MainActor
    func preview(urls: [URL]) {
        self.urls = urls
        guard let panel = QLPreviewPanel.shared() else {
            NSWorkspace.shared.activateFileViewerSelecting(urls)
            return
        }
        panel.dataSource = self
        panel.delegate = self
        panel.makeKeyAndOrderFront(nil)
        panel.reloadData()
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        urls.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        urls[index] as NSURL
    }
}
