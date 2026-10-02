import SwiftUI

/// Left navigation pane: Home, iCloud Drive, Quick access pins and "This Mac", each expandable into a folder tree.
struct NavigationPane: View {
    let model: ExplorerWindowModel
    let tab: BrowserTab
    @State private var volumes = VolumeMonitor.shared
    @State private var quickAccess = QuickAccess.shared
    @State private var tree = FolderTree()
    @State private var isThisMacExpanded = true

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 1) {
                section(StandardLocations.home, key: "home")
                if let iCloud = StandardLocations.iCloudDrive {
                    section(iCloud, key: "icloud")
                }
                divider
                ForEach(quickAccess.locations) { location in
                    section(location, key: "pin:" + location.url.path, pinned: true)
                }
                divider
                NavigationRow(
                    title: "This Mac",
                    icon: AnyView(symbol("desktopcomputer", tint: Theme.accent.swiftUI)),
                    isSelected: false,
                    expansion: $isThisMacExpanded,
                    action: { isThisMacExpanded.toggle() }
                )
                if isThisMacExpanded {
                    ForEach(volumes.volumes) { volume in
                        section(volume, key: "vol:" + volume.url.path, indent: 1, ejectable: volume.url.path != "/")
                    }
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 6)
        }
        .scrollIndicators(.automatic)
        .background(Theme.content.swiftUI)
    }

    private var divider: some View {
        Rectangle()
            .fill(Theme.divider.swiftUI)
            .frame(height: 1)
            .padding(.vertical, 6)
            .padding(.horizontal, 6)
    }

    /// A top-level entry plus its expanded subfolders.
    @ViewBuilder
    private func section(_ location: Location, key: String, pinned: Bool = false, indent: Int = 0, ejectable: Bool = false) -> some View {
        NavigationRow(
            title: location.title,
            icon: AnyView(symbol(location.symbol, tint: location.tint)),
            isSelected: tab.url == location.url.normalizedFileURL,
            indent: indent,
            expansion: expansion(key: key, url: location.url),
            trailingSymbol: pinned ? "pin" : nil,
            action: { open(location.url) }
        )
        .help(location.url.path)
        .folderDropTarget(location.url)
        .contextMenu { folderMenu(location.url, ejectable: ejectable ? location : nil) }

        ForEach(tree.rows(under: location.url, section: key)) { row in
            NavigationRow(
                title: FileManager.default.displayName(atPath: row.url.path),
                icon: AnyView(Image(nsImage: FileIcons.folder).resizable().frame(width: 16, height: 16).frame(width: 18)),
                isSelected: tab.url == row.url,
                indent: indent + row.depth,
                expansion: expansion(key: row.key, url: row.url),
                action: { open(row.url) }
            )
            .help(row.url.path)
            .folderDropTarget(row.url)
            .contextMenu { folderMenu(row.url) }
        }
    }

    /// Chevron state for a folder; hidden once it's known to have no subfolders.
    private func expansion(key: String, url: URL) -> Binding<Bool>? {
        if let children = tree.knownChildren(key), children.isEmpty, !tree.isExpanded(key) { return nil }
        return Binding(
            get: { tree.isExpanded(key) },
            set: { _ in tree.toggle(key, url: url) }
        )
    }

    private func open(_ url: URL) {
        tab.navigate(to: url)
        tab.requestListFocus()
    }

    @ViewBuilder
    private func folderMenu(_ url: URL, ejectable volume: Location? = nil) -> some View {
        Button("Open") { open(url) }
        Button("Open in new tab") { model.newTab(url: url) }
        Divider()
        if quickAccess.isPinned(url) {
            Button("Unpin from Quick access") { quickAccess.unpin(url) }
        } else {
            Button("Pin to Quick access") { quickAccess.pin(url) }
        }
        Button("Show in Finder") { NSWorkspace.shared.open(url) }
        if let volume {
            Divider()
            Button("Eject") { volumes.eject(volume) }
        }
    }

    private func symbol(_ name: String, tint: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: 14))
            .foregroundStyle(tint)
            .frame(width: 18, height: 18)
    }
}

private struct NavigationRow: View {
    let title: String
    let icon: AnyView
    let isSelected: Bool
    var indent = 0
    var expansion: Binding<Bool>? = nil
    var trailingSymbol: String? = nil
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            Group {
                if let expansion {
                    Image(systemName: expansion.wrappedValue ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.secondaryText.swiftUI)
                        .frame(width: 12, height: 20)
                        .contentShape(Rectangle())
                        .onTapGesture { expansion.wrappedValue.toggle() }
                }
            }
            .frame(width: 12)
            .padding(.leading, CGFloat(indent) * 16)

            icon
            Text(title)
                .font(Theme.font)
                .foregroundStyle(Theme.text.swiftUI)
                .lineLimit(1)
            Spacer(minLength: 4)
            if let trailingSymbol {
                Image(systemName: trailingSymbol)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.tertiaryText.swiftUI)
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 30)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isSelected ? Theme.selection.swiftUI : isHovered ? Theme.subtleHover.swiftUI : .clear)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .onHover { isHovered = $0 }
    }
}
