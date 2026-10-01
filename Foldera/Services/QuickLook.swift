import Quartz

/// Space-bar Quick Look panel for the current selection, like Finder.
final class QuickLook: NSObject, QLPreviewPanelDataSource {
    static let shared = QuickLook()

    /// Supplies the selected files; set by the file view that owns the panel.
    var urls: () -> [URL] = { [] }

    private var panel: QLPreviewPanel? { QLPreviewPanel.sharedPreviewPanelExists() ? QLPreviewPanel.shared() : nil }

    func toggle(urls: @escaping () -> [URL]) {
        self.urls = urls
        if let panel, panel.isVisible {
            panel.orderOut(nil)
        } else if !urls().isEmpty {
            QLPreviewPanel.shared()?.makeKeyAndOrderFront(nil)
        }
    }

    /// Call when the selection changes so an open panel follows it.
    func selectionChanged() {
        guard let panel, panel.isVisible else { return }
        panel.reloadData()
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        urls().count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        let urls = urls()
        return index < urls.count ? urls[index] as NSURL : nil
    }
}
