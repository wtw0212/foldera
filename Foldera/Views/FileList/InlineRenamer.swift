import AppKit

/// In-place rename of an item label, shared by the details list and the icon views.
/// Return commits, Esc cancels; with extensions hidden only the stem is edited, like Explorer.
final class InlineRenamer: NSObject, NSTextFieldDelegate {
    private struct Session {
        let field: NSTextField
        let url: URL
        let keepExtension: String?
        let setEditing: (Bool) -> Void
        weak var tab: BrowserTab?
    }

    private var session: Session?
    private var cancelled = false
    /// Called after editing ends so the owner can refresh the item and take focus back.
    var onFinish: (() -> Void)?

    var isEditing: Bool { session != nil }

    func begin(field: NSTextField, item: FileItem, showExtensions: Bool, tab: BrowserTab, setEditing: @escaping (Bool) -> Void) {
        let ext = (item.name as NSString).pathExtension
        let stem = (item.name as NSString).deletingPathExtension
        let keepExtension = !showExtensions && !item.isNavigable && !ext.isEmpty ? ext : nil
        session = Session(field: field, url: item.url, keepExtension: keepExtension, setEditing: setEditing, tab: tab)
        cancelled = false

        field.stringValue = keepExtension == nil ? item.name : stem
        field.delegate = self
        setEditing(true)
        field.window?.makeFirstResponder(field)
        // Select the name without its extension.
        let selected = !item.isNavigable && !ext.isEmpty ? stem : field.stringValue
        field.currentEditor()?.selectedRange = NSRange(location: 0, length: (selected as NSString).length)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        cancelled = true
        control.abortEditing()
        finish()
        return true
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        finish()
    }

    private func finish() {
        guard let session else { return }
        self.session = nil
        let newName = session.field.stringValue + (session.keepExtension.map { ".\($0)" } ?? "")
        session.setEditing(false)
        if cancelled || newName == session.url.lastPathComponent {
            session.tab?.renameRequest = nil
        } else {
            session.tab?.commitRename(of: session.url, to: newName)
        }
        onFinish?()
    }
}
