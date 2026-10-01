import SwiftUI

/// Left navigation pane: Home, iCloud Drive, pinned folders and "This Mac" volumes.
struct NavigationPane: View {
    let model: ExplorerWindowModel
    let tab: BrowserTab
    @State private var volumes = VolumeMonitor.shared
    @State private var isThisMacExpanded = true

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 1) {
                row(StandardLocations.home)
                if let iCloud = StandardLocations.iCloudDrive {
                    row(iCloud)
                }
                divider
                ForEach(StandardLocations.pinned) { location in
                    row(location, pinned: true)
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
                        row(volume, indent: 1, ejectable: volume.url.path != "/")
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

    private func row(_ location: Location, pinned: Bool = false, indent: Int = 0, ejectable: Bool = false) -> some View {
        NavigationRow(
            title: location.title,
            icon: AnyView(symbol(location.symbol, tint: location.tint)),
            isSelected: tab.url == location.url.normalizedFileURL,
            indent: indent,
            trailingSymbol: pinned ? "pin" : nil,
            action: {
                tab.navigate(to: location.url)
                tab.requestListFocus()
            }
        )
        .help(location.url.path)
        .contextMenu {
            Button("Open") { tab.navigate(to: location.url) }
            Button("Open in new tab") { model.newTab(url: location.url) }
            Button("Show in Finder") { NSWorkspace.shared.open(location.url) }
            if ejectable {
                Divider()
                Button("Eject") { volumes.eject(location) }
            }
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
