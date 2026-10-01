import AppKit

/// Commands the table forwards to its owner. Keeps key handling and the responder chain in AppKit
/// while the actual behavior lives in `BrowserTab`.
@MainActor
protocol FileTableCommands: AnyObject {
    func openSelection()
    func beginRename()
    func goUp()
    func goBack()
    func trashSelection()
    func cutSelection()
    func copySelection()
    func paste()
    var hasSelection: Bool { get }
    var canPaste: Bool { get }
    func contextMenu(forRow row: Int) -> NSMenu?
}

final class FileTableView: NSTableView {
    weak var commands: FileTableCommands?

    override func keyDown(with event: NSEvent) {
        guard let commands else { return super.keyDown(with: event) }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function])
        switch (event.keyCode, flags) {
        case (36, []), (76, []): // Return / Enter opens, like Explorer
            commands.openSelection()
        case (125, .command): // ⌘↓
            commands.openSelection()
        case (126, .command): // ⌘↑
            commands.goUp()
        case (120, []): // F2
            commands.beginRename()
        case (51, []): // ⌫ goes back, like Explorer's Backspace
            commands.goBack()
        case (51, .command), (117, []): // ⌘⌫ or forward delete
            commands.trashSelection()
        default:
            super.keyDown(with: event)
        }
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
    @objc func undo(_ sender: Any?) { FileUndo.shared.undo() }
    @objc func redo(_ sender: Any?) { FileUndo.shared.redo() }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)), #selector(cut(_:)), #selector(delete(_:)):
            return commands?.hasSelection ?? false
        case #selector(paste(_:)):
            return commands?.canPaste ?? false
        case #selector(undo(_:)):
            (item as? NSMenuItem)?.title = FileUndo.shared.undoTitle
            return FileUndo.shared.canUndo
        case #selector(redo(_:)):
            (item as? NSMenuItem)?.title = FileUndo.shared.redoTitle
            return FileUndo.shared.canRedo
        default:
            return super.validateUserInterfaceItem(item)
        }
    }

    override func drawBackground(inClipRect clipRect: NSRect) {
        Theme.content.setFill()
        clipRect.fill()
    }
}
