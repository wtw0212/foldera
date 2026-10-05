import Quartz

/// Space-bar Quick Look panel for the current selection, like Finder.
final class QuickLook: NSObject, QLPreviewPanelDataSource {
    static let shared = QuickLook()

    /// Supplies the selected files; set by the file view that owns the panel.
    var urls: () -> [URL] = { [] }
    /// The selection as the view gives it, archive items included.
    private var selection: () -> [URL] = { [] }

    private var panel: QLPreviewPanel? { QLPreviewPanel.sharedPreviewPanelExists() ? QLPreviewPanel.shared() : nil }

    func toggle(urls: @escaping () -> [URL]) {
        // Quick Look reads local files only: items inside archives are shown from copies taken out for it,
        // and server files are previewed by opening them.
        selection = urls
        self.urls = { urls().compactMap { $0.isFileURL ? $0 : ArchivePreviews.shared.cachedFile(for: $0) } }
        if let panel, panel.isVisible {
            panel.orderOut(nil)
            return
        }
        let archived = urls().filter(\.isInArchive)
        Task {
            if !archived.isEmpty, !(await ArchivePreviews.shared.prepare(archived)) { return }
            if !self.urls().isEmpty { QLPreviewPanel.shared()?.makeKeyAndOrderFront(nil) }
        }
    }

    /// Call when the selection changes so an open panel follows it.
    func selectionChanged() {
        guard let panel, panel.isVisible else { return }
        let archived = selection().filter(\.isInArchive)
        guard !archived.isEmpty else { return panel.reloadData() }
        Task {
            _ = await ArchivePreviews.shared.prepare(archived)
            panel.reloadData()
        }
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        urls().count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        let urls = urls()
        return index < urls.count ? urls[index] as NSURL : nil
    }
}
