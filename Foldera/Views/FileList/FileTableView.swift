import AppKit
import Quartz

/// Commands the table forwards to its owner. Keeps key handling and the responder chain in AppKit
/// while the actual behavior lives in `BrowserTab`.
@MainActor
protocol FileViewCommands: AnyObject {
    func openSelection()
    func beginRename()
    func goUp()
    func goBack()
    func trashSelection()
    func cutSelection()
    func copySelection()
    func paste()
    func toggleQuickLook()
    var hasSelection: Bool { get }
    var canPaste: Bool { get }
    func contextMenu(forRow row: Int) -> NSMenu?
}

/// Keyboard shortcuts and Edit-menu validation shared by the list and icon views.
enum FileKeys {
    /// Handles Explorer-style keys; returns false to let the view handle the event.
    static func handle(_ event: NSEvent, _ commands: FileViewCommands) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function])
        switch (event.keyCode, flags) {
        case (36, []), (76, []): // Return / Enter opens like Explorer, or renames like Finder (Settings)
            if AppSettings.shared.returnKeyRenames { commands.beginRename() } else { commands.openSelection() }
        case (125, .command): commands.openSelection() // ⌘↓
        case (126, .command): commands.goUp() // ⌘↑
        case (120, []): commands.beginRename() // F2
        case (51, []): commands.goBack() // ⌫ goes back, like Explorer's Backspace
        case (51, .command), (117, []): commands.trashSelection() // ⌘⌫ or forward delete
        case (49, []): commands.toggleQuickLook() // Space, like Finder
        default: return false
        }
        return true
    }

    /// Validation for copy/cut/paste/delete; nil for other actions.
    static func validate(_ item: any NSValidatedUserInterfaceItem, _ commands: FileViewCommands?) -> Bool? {
        switch item.action {
        case #selector(NSText.copy(_:)), #selector(NSText.cut(_:)), #selector(NSText.delete(_:)):
            return commands?.hasSelection ?? false
        case #selector(NSText.paste(_:)):
            return commands?.canPaste ?? false
        default:
            return nil
        }
    }
}

final class FileTableView: NSTableView {
    weak var commands: FileViewCommands?
    /// Called when the list takes keyboard focus (used to track the active pane).
    var onFocus: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocus?() }
        return accepted
    }

    override func keyDown(with event: NSEvent) {
        if let commands, FileKeys.handle(event, commands) { return }
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        if row >= 0 {
            if !selectedRowIndexes.contains(row) {
                selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
        } else {
            deselectAll(nil)
        }
        window?.makeFirstResponder(self)
        return commands?.contextMenu(forRow: row)
    }

    // MARK: Responder chain (Edit menu)

    @objc func copy(_ sender: Any?) { commands?.copySelection() }
    @objc func cut(_ sender: Any?) { commands?.cutSelection() }
    @objc func paste(_ sender: Any?) { commands?.paste() }
    @objc func delete(_ sender: Any?) { commands?.trashSelection() }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        FileKeys.validate(item, commands) ?? super.validateUserInterfaceItem(item)
    }

    // Quick Look panel control (called on the main thread by the panel).
    nonisolated override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    nonisolated override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { panel.dataSource = QuickLook.shared }
    }
    nonisolated override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {}

    override func drawBackground(inClipRect clipRect: NSRect) {
        Theme.content.setFill()
        clipRect.fill()
    }
}
