import SwiftUI

/// "This Mac": every drive with a usage bar and free space, like Explorer's This PC.
struct ThisMacView: View {
    let tab: BrowserTab
    let openInNewTab: (URL) -> Void
    let openInBackgroundTab: (URL) -> Void
    var onFocus: () -> Void = {}

    @State private var volumes = VolumeMonitor.shared
    @State private var usage: [URL: DriveUsage] = [:]
    @State private var selected: URL?
    @FocusState private var isFocused: Bool

    private var local: [Location] { volumes.volumes.filter { usage[$0.url]?.isNetwork != true } }
    private var network: [Location] { volumes.volumes.filter { usage[$0.url]?.isNetwork == true } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                group(L10n.text("Devices and drives"), local)
                if !network.isEmpty {
                    group(L10n.text("Network locations"), network)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.content.swiftUI)
        .contentShape(Rectangle())
        .onTapGesture { selected = nil; isFocused = true }
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onChange(of: isFocused) { _, focused in if focused { onFocus() } }
        .onChange(of: tab.focusListToken) { isFocused = true }
        .onKeyPress(.return) {
            guard let selected else { return .ignored }
            tab.navigate(to: selected)
            return .handled
        }
        // Free space changes as files are written; refresh while the page is open.
        .task(id: volumes.volumes.map(\.url)) {
            while !Task.isCancelled {
                let urls = volumes.volumes.map(\.url)
                usage = await Task.detached { DriveUsage.load(urls) }.value
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func group(_ title: String, _ drives: [Location]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(title) (\(drives.count))")
                .font(Theme.font.weight(.semibold))
                .foregroundStyle(Theme.text.swiftUI)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 250, maximum: 320), spacing: 8, alignment: .leading)], alignment: .leading, spacing: 8) {
                ForEach(drives) { drive in
                    DriveTile(drive: drive, usage: usage[drive.url], isSelected: selected == drive.url)
                        .onTapGesture(count: 2) { tab.navigate(to: drive.url) }
                        .simultaneousGesture(TapGesture().onEnded { selected = drive.url; isFocused = true })
                        .onMiddleClick { openInBackgroundTab(drive.url) }
                        .contextMenu { menu(drive) }
                        .folderDropTarget(drive.url)
                        .help(drive.url.path)
                }
            }
        }
    }

    @ViewBuilder
    private func menu(_ drive: Location) -> some View {
        Button(L10n.text("Open")) { tab.navigate(to: drive.url) }
        Button(L10n.text("Open in new tab")) { openInNewTab(drive.url) }
        Button(L10n.text("Show in Finder")) { NSWorkspace.shared.open(drive.url) }
        if drive.url.path != "/" {
            Divider()
            Button(L10n.text("Eject")) { volumes.eject(drive) }
        }
    }
}

/// Capacity of a mounted volume.
nonisolated struct DriveUsage: Equatable, Sendable {
    let total: Int64
    let available: Int64
    let isNetwork: Bool

    var used: Int64 { max(0, total - available) }
    var fractionUsed: Double { total > 0 ? Double(used) / Double(total) : 0 }

    static func load(_ urls: [URL]) -> [URL: DriveUsage] {
        var result: [URL: DriveUsage] = [:]
        let keys: Set<URLResourceKey> = [
            .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey, .volumeIsLocalKey,
        ]
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: keys), let total = values.volumeTotalCapacity else { continue }
            // "Important usage" counts purgeable space as free, matching Finder and Get Info.
            let important = values.volumeAvailableCapacityForImportantUsage ?? 0
            let available = important > 0 ? important : Int64(values.volumeAvailableCapacity ?? 0)
            result[url] = DriveUsage(total: Int64(total), available: available, isNetwork: values.volumeIsLocal == false)
        }
        return result
    }
}

struct DriveTile: View {
    let drive: Location
    let usage: DriveUsage?
    let isSelected: Bool
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: FileIcons.icon(forPath: drive.url))
                .resizable()
                .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 5) {
                Text(drive.title)
                    .font(Theme.font)
                    .foregroundStyle(Theme.text.swiftUI)
                    .lineLimit(1)
                if let usage {
                    UsageBar(fraction: usage.fractionUsed)
                    Text(L10n.format("%@ free of %@", Self.format(usage.available), Self.format(usage.total)))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondaryText.swiftUI)
                        .lineLimit(1)
                } else {
                    UsageBar(fraction: 0).opacity(0.4)
                    Text(" ").font(.system(size: 11))
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isSelected ? Theme.selection.swiftUI : isHovered ? Theme.subtleHover.swiftUI : .clear)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityValue(usage.map { L10n.format("%@ free of %@", Self.format($0.available), Self.format($0.total)) } ?? "")
    }

    /// Same units as Finder (1 GB = 1,000,000,000 bytes).
    static func format(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file).locale(L10n.locale))
    }
}

/// Explorer's drive bar: blue, turning red when the drive is over 90% full.
struct UsageBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Rectangle().fill(Theme.divider.swiftUI)
                Rectangle()
                    .fill(fraction > 0.9 ? Color(nsColor: .init(hex: 0xDA3B01)) : Theme.accent.swiftUI)
                    .frame(width: geometry.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: 12)
        .overlay(Rectangle().strokeBorder(Theme.controlStroke.swiftUI, lineWidth: 1))
    }
}
