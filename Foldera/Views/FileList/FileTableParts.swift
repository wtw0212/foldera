import AppKit

// MARK: - Row

/// Row with Explorer-style hover and selection fills. The table decides which single row is hovered.
final class FileRowView: NSTableRowView {
    var isHovered = false {
        didSet { if isHovered != oldValue { needsDisplay = true } }
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }

    override func prepareForReuse() {
        super.prepareForReuse()
        isHovered = false
    }

    /// Like Explorer, the highlight ends at the last column instead of spanning the whole width.
    private var fillRect: NSRect {
        var rect = bounds
        if let table = superview as? FileTableView {
            rect.size.width = min(rect.width, table.columnsMaxX)
        }
        return rect.insetBy(dx: 4, dy: 1)
    }

    override func drawBackground(in dirtyRect: NSRect) {
        guard isHovered, !isSelected else { return }
        Theme.hover.setFill()
        NSBezierPath(roundedRect: fillRect, xRadius: 4, yRadius: 4).fill()
    }

    override func drawSelection(in dirtyRect: NSRect) {
        let color = isEmphasized ? (isHovered ? Theme.selectionHover : Theme.selection) : Theme.selectionInactive
        color.setFill()
        NSBezierPath(roundedRect: fillRect, xRadius: 4, yRadius: 4).fill()
    }
}

// MARK: - Cells

/// Name column cell: icon plus a label that becomes editable for inline rename.
final class NameCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("NameCell")

    let iconView = NSImageView()
    let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        label.font = Theme.nsFont
        label.textColor = Theme.text
        label.lineBreakMode = .byTruncatingTail
        label.cell?.isScrollable = false
        label.cell?.wraps = false
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)
        addSubview(label)
        imageView = iconView
        textField = label
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setEditing(_ editing: Bool) {
        label.isEditable = editing
        label.isSelectable = editing
        label.isBordered = editing
        label.drawsBackground = editing
        label.backgroundColor = editing ? Theme.content : .clear
        label.focusRingType = editing ? .default : .none
    }
}

/// Plain text cell used by Date modified, Type and Size.
final class TextCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("TextCell")

    let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier
        label.font = Theme.nsFont
        label.textColor = Theme.secondaryText
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

// MARK: - Header

/// Explorer column header: flat background, column separators and a chevron sort indicator at the top.
final class ExplorerHeaderCell: NSTableHeaderCell {
    override init(textCell string: String) {
        super.init(textCell: string)
        font = Theme.nsFont
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        Theme.content.setFill()
        cellFrame.fill()

        Theme.divider.setFill()
        NSRect(x: cellFrame.maxX - 1, y: cellFrame.minY + 4, width: 1, height: cellFrame.height - 8).fill()

        let attributes: [NSAttributedString.Key: Any] = [.font: Theme.nsFont, .foregroundColor: Theme.secondaryText]
        let title = NSAttributedString(string: stringValue, attributes: attributes)
        let size = title.size()
        let rect = NSRect(
            x: cellFrame.minX + 10,
            y: cellFrame.midY - size.height / 2,
            width: cellFrame.width - 20,
            height: size.height
        )
        title.draw(with: rect, options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin])

        if let indicator = sortIndicator(in: controlView) {
            drawChevron(in: cellFrame, ascending: indicator, flipped: controlView.isFlipped)
        }
    }

    override func drawSortIndicator(withFrame cellFrame: NSRect, in controlView: NSView, ascending: Bool, priority: Int) {}

    private func sortIndicator(in controlView: NSView) -> Bool? {
        guard let header = controlView as? NSTableHeaderView, let table = header.tableView,
              let descriptor = table.sortDescriptors.first else { return nil }
        let column = table.tableColumns.first { $0.headerCell === self }
        guard column?.sortDescriptorPrototype?.key == descriptor.key else { return nil }
        return descriptor.ascending
    }

    private func drawChevron(in frame: NSRect, ascending: Bool, flipped: Bool) {
        let width: CGFloat = 7, height: CGFloat = 3.5
        let midX = frame.midX
        let top = flipped ? frame.minY + 3 : frame.maxY - 3
        let bottom = flipped ? top + height : top - height
        let path = NSBezierPath()
        // Windows draws "^" for ascending and "v" for descending.
        if ascending {
            path.move(to: NSPoint(x: midX - width / 2, y: bottom))
            path.line(to: NSPoint(x: midX, y: top))
            path.line(to: NSPoint(x: midX + width / 2, y: bottom))
        } else {
            path.move(to: NSPoint(x: midX - width / 2, y: top))
            path.line(to: NSPoint(x: midX, y: bottom))
            path.line(to: NSPoint(x: midX + width / 2, y: top))
        }
        path.lineWidth = 1
        Theme.tertiaryText.setStroke()
        path.stroke()
    }
}

final class ExplorerHeaderView: NSTableHeaderView {
    override func draw(_ dirtyRect: NSRect) {
        Theme.content.setFill()
        dirtyRect.fill()
        super.draw(dirtyRect)
    }
}

// MARK: - Formatting

enum FileFormat {
    static func date(_ date: Date?) -> String {
        date?.formatted(Date.FormatStyle(date: .numeric, time: .shortened).locale(L10n.locale)) ?? ""
    }

    /// Explorer shows sizes in whole kilobytes, rounded up: "1 KB", "2,048 KB".
    static func size(_ bytes: Int64?) -> String {
        guard let bytes else { return "" }
        let kilobytes = bytes == 0 ? 0 : (bytes + 1023) / 1024
        return "\(kilobytes.formatted(.number.locale(L10n.locale))) KB"
    }

    /// Parent folder path for search results, with the home folder shortened to "~".
    static func location(of url: URL) -> String {
        (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
    }

    /// Status bar total: "1.24 MB" style, like Explorer's selection summary.
    static func totalSize(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .binary).locale(L10n.locale))
    }
}
