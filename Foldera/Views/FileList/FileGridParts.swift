import AppKit
import Quartz

// MARK: - Layout

/// Flow layout whose cell size follows the view mode. List flows in columns; Content fills the width.
final class FileGridLayout: NSCollectionViewFlowLayout {
    var mode: ViewMode = .largeIcons {
        didSet { if mode != oldValue { configure() } }
    }

    override init() {
        super.init()
        configure()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func configure() {
        scrollDirection = mode == .list ? .horizontal : .vertical
        sectionInset = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        minimumInteritemSpacing = mode == .content ? 0 : 4
        minimumLineSpacing = mode == .content ? 0 : 4
        updateItemSize()
        invalidateLayout()
    }

    private func updateItemSize() {
        let width = (collectionView?.bounds.width ?? 800) - 16
        itemSize = switch mode {
        case .extraLargeIcons: NSSize(width: 276, height: 304)
        case .largeIcons: NSSize(width: 116, height: 140)
        case .mediumIcons: NSSize(width: 88, height: 96)
        case .smallIcons: NSSize(width: 220, height: 24)
        case .list: NSSize(width: 260, height: 24)
        case .tiles: NSSize(width: 260, height: 68)
        case .content: NSSize(width: max(320, width), height: 72)
        case .details: NSSize(width: max(320, width), height: 24)
        }
    }

    override func prepare() {
        updateItemSize()
        super.prepare()
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        mode == .content ? newBounds.width != collectionView?.bounds.width : super.shouldInvalidateLayout(forBoundsChange: newBounds)
    }
}

// MARK: - Cell

/// One item in the icon, list, tiles or content layouts.
final class FileGridCell: NSView {
    let iconView = NSImageView()
    let nameLabel = NSTextField(labelWithString: "")
    private let detailLabels = (0..<3).map { _ in NSTextField(labelWithString: "") }

    var mode: ViewMode = .largeIcons {
        didSet { if mode != oldValue { applyMode() } }
    }
    var isSelected = false { didSet { needsDisplay = true } }
    /// Set by the collection view, which tracks the single item under the pointer.
    var isHovered = false { didSet { if isHovered != oldValue { needsDisplay = true } } }
    private var isEditingName = false

    override var isFlipped: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Clicks go to the collection view for selection and dragging; only the rename field takes them while editing.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        if isEditingName, hit === nameLabel || hit.isDescendant(of: nameLabel) { return hit }
        return self
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(iconView)
        for label in [nameLabel] + detailLabels {
            label.font = Theme.nsFont
            label.lineBreakMode = .byTruncatingTail
            label.cell?.truncatesLastVisibleLine = true
            addSubview(label)
        }
        applyMode()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(item: FileItem, mode: ViewMode, showExtensions: Bool, dimmed: Bool) {
        self.mode = mode
        nameLabel.stringValue = item.title(showExtensions: showExtensions)
        let details: [String] = switch mode {
        case .tiles:
            [item.localizedKind, item.isNavigable ? "" : FileFormat.size(item.size)]
        case .content:
            [
                item.localizedKind,
                item.dateModified.map { L10n.format("Date modified: %@", FileFormat.date($0)) } ?? "",
                item.isNavigable ? "" : L10n.format("Size: %@", FileFormat.size(item.size)),
            ]
        default: []
        }
        for (index, label) in detailLabels.enumerated() {
            label.stringValue = index < details.count ? details[index] : ""
            label.isHidden = index >= details.count
        }
        alphaValue = dimmed ? 0.5 : 1
        // Hidden items get a faded icon and gray name, like Explorer.
        iconView.alphaValue = item.isHidden ? 0.45 : 1
        nameLabel.textColor = item.isHidden ? Theme.tertiaryText : Theme.text
        toolTip = item.name
        needsLayout = true
    }

    func setEditing(_ editing: Bool) {
        isEditingName = editing
        nameLabel.isEditable = editing
        nameLabel.isSelectable = editing
        nameLabel.isBordered = editing
        nameLabel.drawsBackground = editing
        nameLabel.backgroundColor = Theme.content
        nameLabel.maximumNumberOfLines = editing ? 1 : (isIconMode ? 2 : 1)
        needsLayout = true
    }

    private var isIconMode: Bool {
        [.extraLargeIcons, .largeIcons, .mediumIcons].contains(mode)
    }

    private func applyMode() {
        nameLabel.alignment = isIconMode ? .center : .left
        nameLabel.maximumNumberOfLines = isIconMode ? 2 : 1
        nameLabel.lineBreakMode = isIconMode ? .byWordWrapping : .byTruncatingTail
        nameLabel.textColor = Theme.text
        for label in detailLabels { label.textColor = Theme.secondaryText }
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        let icon = mode.iconSize
        switch mode {
        case .extraLargeIcons, .largeIcons, .mediumIcons:
            iconView.frame = NSRect(x: (w - icon) / 2, y: 6, width: icon, height: icon)
            let top = 6 + icon + 4
            let height = isEditingName ? 22 : min(h - top - 2, 32)
            nameLabel.frame = NSRect(x: 4, y: top, width: w - 8, height: height)
        case .smallIcons, .list, .details:
            iconView.frame = NSRect(x: 6, y: (h - 16) / 2, width: 16, height: 16)
            nameLabel.frame = NSRect(x: 28, y: (h - 18) / 2, width: w - 32, height: 18)
        case .tiles:
            iconView.frame = NSRect(x: 8, y: (h - icon) / 2, width: icon, height: icon)
            let x = 8 + icon + 10
            nameLabel.frame = NSRect(x: x, y: 8, width: w - x - 6, height: 18)
            detailLabels[0].frame = NSRect(x: x, y: 26, width: w - x - 6, height: 16)
            detailLabels[1].frame = NSRect(x: x, y: 42, width: w - x - 6, height: 16)
        case .content:
            iconView.frame = NSRect(x: 12, y: (h - icon) / 2, width: icon, height: icon)
            let x = 12 + icon + 12
            let right = max(x + 200, w * 0.62)
            nameLabel.frame = NSRect(x: x, y: 16, width: right - x - 12, height: 18)
            detailLabels[0].frame = NSRect(x: x, y: 38, width: right - x - 12, height: 16)
            detailLabels[1].frame = NSRect(x: right, y: 16, width: w - right - 12, height: 16)
            detailLabels[2].frame = NSRect(x: right, y: 38, width: w - right - 12, height: 16)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = mode == .content ? bounds.insetBy(dx: 2, dy: 1) : bounds
        let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
        if isSelected {
            let focused = window?.isKeyWindow == true && window?.firstResponder is FileCollectionView
            (focused ? (isHovered ? Theme.selectionHover : Theme.selection) : Theme.selectionInactive).setFill()
            path.fill()
        } else if isHovered {
            Theme.hover.setFill()
            path.fill()
        }
        if mode == .content {
            Theme.divider.setFill()
            NSRect(x: 8, y: bounds.maxY - 1, width: bounds.width - 16, height: 1).fill()
        }
    }

}

final class FileGridItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("FileGridItem")

    /// The file shown, used to drop stale async thumbnails.
    var representedURL: URL?
    var cell: FileGridCell { view as! FileGridCell }

    override func loadView() {
        view = FileGridCell()
    }

    override var isSelected: Bool {
        didSet { cell.isSelected = isSelected }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        representedURL = nil
        cell.setEditing(false)
        cell.isHovered = false
    }
}

// MARK: - Collection view

/// Icon-view counterpart of `FileTableView`: Explorer keys, context menus, double-click to open.
final class FileCollectionView: NSCollectionView {
    weak var commands: FileViewCommands?
    var onDoubleClick: ((IndexPath) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    /// Like Finder and Explorer, a click on an inactive window also selects.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let indexPath = indexPathForItem(at: point)
        slowClick.mouseDown(event, wasOnlySelection: indexPath.map { selectionIndexPaths == [$0] } ?? false,
                            onLabel: indexPath.map { isOnNameLabel(point, at: $0) } ?? false,
                            wasFocused: window?.isKeyWindow == true && window?.firstResponder === self)
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
        if event.clickCount == 2, let indexPath {
            onDoubleClick?(indexPath)
        }
        if let release = NSApp.currentEvent, release.type == .leftMouseUp, let indexPath { slowClickReleased(release, at: indexPath) }
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        if let indexPath = indexPathForItem(at: convert(event.locationInWindow, from: nil)) { slowClickReleased(event, at: indexPath) }
    }

    // MARK: Slow click to rename

    let slowClick = SlowClickRename()

    private func slowClickReleased(_ event: NSEvent, at indexPath: IndexPath) {
        slowClick.mouseUp(at: event.locationInWindow) { [weak self] in
            guard let self, selectionIndexPaths == [indexPath], window?.firstResponder === self else { return }
            commands?.beginRename()
        }
    }

    /// Only the name renames, like Explorer; the icon and details just select.
    func isOnNameLabel(_ point: NSPoint, at indexPath: IndexPath) -> Bool {
        guard let cell = (item(at: indexPath) as? FileGridItem)?.cell else { return false }
        return cell.convert(cell.nameLabel.frame, to: self).contains(point)
    }

    override func otherMouseUp(with event: NSEvent) {
        slowClick.cancel()
        guard event.buttonNumber == 2 else { return super.otherMouseUp(with: event) }
        if let indexPath = indexPathForItem(at: convert(event.locationInWindow, from: nil)) {
            commands?.openInBackgroundTab(index: indexPath.item)
        }
    }

    override func keyDown(with event: NSEvent) {
        slowClick.cancel()
        if let commands, FileKeys.handle(event, commands) { return }
        super.keyDown(with: event)
    }

    private var zoomGesture = ZoomGesture()

    override func magnify(with event: NSEvent) {
        guard let commands else { return super.magnify(with: event) }
        let step = zoomGesture.step(for: event)
        if step != 0 { commands.zoom(in: step > 0) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        slowClick.cancel()
        window?.makeFirstResponder(self)
        let indexPath = indexPathForItem(at: convert(event.locationInWindow, from: nil))
        if let indexPath {
            if !selectionIndexPaths.contains(indexPath) {
                deselectAll(nil)
                selectItems(at: [indexPath], scrollPosition: [])
                delegate?.collectionView?(self, didSelectItemsAt: [indexPath])
            }
        } else if !selectionIndexPaths.isEmpty {
            let previous = selectionIndexPaths
            deselectAll(nil)
            delegate?.collectionView?(self, didDeselectItemsAt: previous)
        }
        return commands?.contextMenu(forRow: indexPath?.item ?? -1)
    }

    // MARK: Hover (one tracking area for the whole grid; see FileTableView)

    private var hoverTracking: NSTrackingArea?
    private var hoveredIndex: IndexPath? {
        didSet { if hoveredIndex != oldValue { applyHover() } }
    }

    private func applyHover() {
        for indexPath in indexPathsForVisibleItems() {
            (item(at: indexPath) as? FileGridItem)?.cell.isHovered = indexPath == hoveredIndex
        }
    }

    func refreshHover() {
        guard let window else { hoveredIndex = nil; return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        hoveredIndex = window.isKeyWindow && visibleRect.contains(point) ? indexPathForItem(at: point) : nil
        applyHover()
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
        hoveredIndex = indexPathForItem(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hoveredIndex = nil
    }

    override func scrollWheel(with event: NSEvent) {
        if ZoomGesture.isZoomScroll(event), let commands {
            let step = zoomGesture.step(for: event)
            if step != 0 { commands.zoom(in: step > 0) }
            return
        }
        slowClick.cancel()
        super.scrollWheel(with: event)
        refreshHover()
    }

    override func reloadData() {
        slowClick.cancel()
        super.reloadData()
        DispatchQueue.main.async { [weak self] in self?.refreshHover() }
    }

    /// Called when the grid takes keyboard focus (used to track the active pane).
    var onFocus: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        visibleItems().forEach { $0.view.needsDisplay = true }
        let accepted = super.becomeFirstResponder()
        if accepted { onFocus?() }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        slowClick.cancel()
        visibleItems().forEach { $0.view.needsDisplay = true }
        return super.resignFirstResponder()
    }

    // Quick Look panel control (called on the main thread by the panel).
    nonisolated override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    nonisolated override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { panel.dataSource = QuickLook.shared }
    }
    nonisolated override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {}

    @objc func copy(_ sender: Any?) { commands?.copySelection() }
    @objc func cut(_ sender: Any?) { commands?.cutSelection() }
    @objc func paste(_ sender: Any?) { commands?.paste() }
    @objc func delete(_ sender: Any?) { commands?.trashSelection() }

}

extension FileCollectionView: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        FileKeys.validate(menuItem, commands) ?? true
    }
}
