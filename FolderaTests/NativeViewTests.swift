import AppKit
import Testing
@testable import Foldera

@MainActor
struct NativeViewTests {
    private func rendered(_ view: NSView) throws -> Data {
        let image = NSImage(size: view.bounds.size)
        image.lockFocus()
        view.draw(view.bounds)
        image.unlockFocus()
        return try #require(image.tiffRepresentation)
    }

    @Test func everyFileKindDrawsADistinctCachedIcon() throws {
        var images = Set<Data>()
        for kind in FileKind.allCases {
            let image = FileTypeIcons.image(for: kind)
            #expect(image === FileTypeIcons.image(for: kind))
            #expect(image.size == NSSize(width: 16, height: 16))
            images.insert(try #require(image.tiffRepresentation))
        }
        #expect(images.count == FileKind.allCases.count)
    }

    @Test func everyGridLayoutHasTheExpectedSizeAndScrollDirection() {
        let collection = FileCollectionView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        let layout = FileGridLayout()
        collection.collectionViewLayout = layout
        let expected: [ViewMode: NSSize] = [
            .extraLargeIcons: NSSize(width: 276, height: 304), .largeIcons: NSSize(width: 116, height: 140),
            .mediumIcons: NSSize(width: 88, height: 96), .smallIcons: NSSize(width: 220, height: 24),
            .list: NSSize(width: 260, height: 24), .tiles: NSSize(width: 260, height: 68),
            .content: NSSize(width: 784, height: 72), .details: NSSize(width: 784, height: 24),
        ]
        for mode in ViewMode.allCases {
            layout.mode = mode
            layout.prepare()
            #expect(layout.itemSize == expected[mode])
            #expect(layout.scrollDirection == (mode == .list ? .horizontal : .vertical))
            #expect(layout.minimumLineSpacing == (mode == .content ? 0 : 4))
        }
        layout.mode = .content
        #expect(layout.shouldInvalidateLayout(forBoundsChange: NSRect(x: 0, y: 0, width: 900, height: 500)))
        #expect(!layout.shouldInvalidateLayout(forBoundsChange: collection.bounds))
    }

    @Test func gridCellsLayOutLabelsAndReflectHiddenCutSelectionAndRenameStates() throws {
        let directory = try TestDirectory()
        let file = FileItem(url: try directory.file("photo.txt")), hidden = FileItem(url: try directory.file(".hidden"))
        let folder = FileItem(url: try directory.folder("folder"))
        let cell = FileGridCell(frame: NSRect(x: 0, y: 0, width: 800, height: 320))
        #expect(cell.isFlipped && cell.acceptsFirstMouse(for: nil))
        for mode in ViewMode.allCases {
            cell.configure(item: file, mode: mode, showExtensions: false, dimmed: false)
            cell.layout()
            #expect(cell.nameLabel.stringValue == "photo" && cell.iconView.frame.width == mode.iconSize)
            #expect(cell.nameLabel.frame.width > 0 && cell.nameLabel.frame.height > 0)
            #expect(!cell.nameLabel.isEditable && cell.alphaValue == 1)
            cell.isHovered = true
            let hovered = try rendered(cell)
            cell.isSelected = true
            #expect(try rendered(cell) != hovered)
            cell.setEditing(true)
            cell.layout()
            #expect(cell.nameLabel.isEditable && cell.nameLabel.isSelectable && cell.nameLabel.maximumNumberOfLines == 1)
            cell.setEditing(false)
            cell.isSelected = false
            cell.isHovered = false
        }
        cell.configure(item: hidden, mode: .tiles, showExtensions: true, dimmed: true)
        #expect(cell.alphaValue == 0.5 && cell.iconView.alphaValue == 0.45)
        cell.configure(item: folder, mode: .content, showExtensions: true, dimmed: false)
        cell.layout()
        #expect(cell.nameLabel.stringValue == "folder" && cell.toolTip == "folder")
        #expect(cell.hitTest(NSPoint(x: 20, y: 20)) === cell)
        #expect(cell.hitTest(NSPoint(x: -1, y: -1)) == nil)
    }

    @Test func recycledItemsAndRowsClearTransientState() {
        let item = FileGridItem()
        item.loadView()
        item.representedURL = URL(fileURLWithPath: "/tmp/file")
        item.isSelected = true
        item.cell.isHovered = true
        item.cell.setEditing(true)
        #expect(item.cell.isSelected)
        item.prepareForReuse()
        #expect(item.representedURL == nil && !item.cell.isHovered && !item.cell.nameLabel.isEditable)
        let row = FileRowView()
        row.isHovered = true
        row.prepareForReuse()
        #expect(!row.isHovered && row.interiorBackgroundStyle == .normal)
    }

    @Test func nameCellsSwitchEditingPropertiesAndTextCellsExposeTheirLabels() {
        let cell = NameCellView(frame: NSRect(x: 0, y: 0, width: 300, height: 30))
        #expect(cell.textField === cell.label && cell.imageView === cell.iconView)
        for editing in [true, false] {
            cell.setEditing(editing)
            #expect(cell.label.isEditable == editing && cell.label.isSelectable == editing)
            #expect(cell.label.drawsBackground == editing && cell.label.isBordered == editing)
        }
        let text = TextCellView(frame: .zero)
        #expect(text.textField === text.label && text.identifier == TextCellView.identifier)
    }

    @Test func formattersHandleMissingDatesAndRoundKilobytesUp() {
        #expect(FileFormat.date(nil).isEmpty && FileFormat.size(nil).isEmpty)
        #expect(FileFormat.size(0) == "0 KB")
        #expect(FileFormat.size(1) == "1 KB" && FileFormat.size(1024) == "1 KB" && FileFormat.size(1025) == "2 KB")
        #expect(!FileFormat.date(Date(timeIntervalSince1970: 0)).isEmpty)
        #expect(!FileFormat.totalSize(1024).isEmpty)
        #expect(FileFormat.location(of: URL(fileURLWithPath: "/tmp/folder/file")) == "/tmp/folder")
    }

    @Test func driveUsageHandlesZeroCapacityAndPurgeableSpace() {
        #expect(DriveUsage(total: 0, available: 0, isNetwork: false).fractionUsed == 0)
        #expect(DriveUsage(total: 100, available: 120, isNetwork: false).used == 0)
        #expect(DriveUsage(total: 100, available: 25, isNetwork: true).fractionUsed == 0.75)
        let root = URL(fileURLWithPath: "/")
        let loaded = DriveUsage.load([root, URL(fileURLWithPath: "/nonexistent-foldera-volume")])
        #expect(loaded[root]?.total ?? 0 > 0 && loaded.count == 1)
    }

    @Test func tableHeadersDrawDistinctAscendingAndDescendingIndicators() throws {
        let table = FileTableView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let header = ExplorerHeaderView(frame: NSRect(x: 0, y: 0, width: 300, height: 30))
        table.headerView = header
        let column = NSTableColumn(identifier: .init("name"))
        let cell = ExplorerHeaderCell(textCell: "Name")
        column.headerCell = cell
        column.sortDescriptorPrototype = NSSortDescriptor(key: "name", ascending: true)
        table.addTableColumn(column)
        func draw() throws -> Data {
            let image = NSImage(size: NSSize(width: 300, height: 30))
            image.lockFocus()
            cell.draw(withFrame: NSRect(x: 0, y: 0, width: 300, height: 30), in: header)
            image.unlockFocus()
            return try #require(image.tiffRepresentation)
        }
        let unsorted = try draw()
        table.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
        let ascending = try draw()
        table.sortDescriptors = [NSSortDescriptor(key: "name", ascending: false)]
        let descending = try draw()
        #expect(unsorted != ascending && ascending != descending && descending != unsorted)
        #expect(try !rendered(header).isEmpty)
    }

    @Test func rowHighlightsReflectHoverFocusAndSelection() throws {
        let table = FileTableView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let column = NSTableColumn(identifier: .init("name"))
        column.width = 180
        table.addTableColumn(column)
        let row = FileRowView(frame: NSRect(x: 0, y: 0, width: 400, height: 30))
        table.addSubview(row)
        func draw(selection: Bool) throws -> Data {
            let image = NSImage(size: row.bounds.size)
            image.lockFocus()
            NSColor.white.setFill()
            row.bounds.fill()
            if selection { row.drawSelection(in: row.bounds) } else { row.drawBackground(in: row.bounds) }
            image.unlockFocus()
            return try #require(image.tiffRepresentation)
        }
        let idle = try draw(selection: false)
        row.isHovered = true
        let hovered = try draw(selection: false)
        #expect(hovered != idle)
        row.isSelected = true
        #expect(try draw(selection: false) == idle)
        row.isEmphasized = true
        let active = try draw(selection: true)
        row.isHovered = false
        #expect(try draw(selection: true) != active)
        row.isEmphasized = false
        #expect(try draw(selection: true) != active)
    }
}
