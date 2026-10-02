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

    /// Right edge of the last visible column; the empty area beyond it isn't part of any row.
    var columnsMaxX: CGFloat {
        numberOfColumns > 0 ? rect(ofColumn: numberOfColumns - 1).maxX : bounds.width
    }

    /// The row under `point`, or -1 in the empty space right of the columns (Explorer behavior).
    func rowInColumns(at point: NSPoint) -> Int {
        point.x > columnsMaxX ? -1 : row(at: point)
    }

    /// Row highlights follow the column edge, so redraw them when columns change size or order.
    override func tile() {
        super.tile()
        enumerateAvailableRowViews { rowView, _ in rowView.needsDisplay = true }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if point.x > columnsMaxX {
            // Clicking empty space clears the selection instead of selecting the row.
            window?.makeFirstResponder(self)
            deselectAll(nil)
            return
        }
        super.mouseDown(with: event)
    }

    // MARK: Hover
    // One tracking area for the whole list, so at most one row is ever highlighted. Per-row tracking
    // missed "mouse exited" events when rows were scrolled or reloaded under the pointer, leaving
    // stale highlights behind.

    private var hoverTracking: NSTrackingArea?
    private var hoveredRow = -1 {
        didSet {
            guard hoveredRow != oldValue else { return }
            setHover(oldValue, false)
            setHover(hoveredRow, true)
        }
    }

    private func setHover(_ row: Int, _ hovered: Bool) {
        guard row >= 0, row < numberOfRows else { return }
        (rowView(atRow: row, makeIfNecessary: false) as? FileRowView)?.isHovered = hovered
    }

    /// Re-reads which row is under the pointer (after scrolling, reloading or a mouse move).
    func refreshHover() {
        guard let window else { hoveredRow = -1; return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        let inside = visibleRect.contains(point) && window.isKeyWindow
        // Clear every row first so nothing stale survives a reload.
        let visible = rows(in: visibleRect)
        for row in visible.location..<(visible.location + visible.length) {
            if let view = rowView(atRow: row, makeIfNecessary: false) as? FileRowView, view.isHovered, row != hoveredRow {
                view.isHovered = false
            }
        }
        let row = inside ? rowInColumns(at: point) : -1
        if row == hoveredRow { setHover(row, true) } else { hoveredRow = row }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverTracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        hoveredRow = rowInColumns(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hoveredRow = -1
    }

    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        refreshHover()
    }

    override func reloadData() {
        super.reloadData()
        DispatchQueue.main.async { [weak self] in self?.refreshHover() }
    }

    override func didAdd(_ rowView: NSTableRowView, forRow row: Int) {
        super.didAdd(rowView, forRow: row)
        (rowView as? FileRowView)?.isHovered = row == hoveredRow
    }

    override func keyDown(with event: NSEvent) {
        if let commands, FileKeys.handle(event, commands) { return }
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = rowInColumns(at: convert(event.locationInWindow, from: nil))
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
