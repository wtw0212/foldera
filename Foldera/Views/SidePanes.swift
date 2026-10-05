import ImageIO
import Quartz
import SwiftUI

struct QuickLookPreview: NSViewRepresentable {
    let url: URL
    /// Off by default: a selected video shows its first frame and a play button instead of playing.
    var autostarts = false

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.shouldCloseWithWindow = false
        view.autostarts = autostarts
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        view.autostarts = autostarts
        if (view.previewItem as? NSURL) as URL? != url {
            view.previewItem = url as NSURL
        }
    }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) {
        view.close()
    }
}

/// Explorer's Details pane: a live Quick Look preview (or large icon) plus the item's properties.
struct DetailsPane: View {
    let tab: BrowserTab

    var body: some View {
        let selected = tab.selectedItems
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if selected.count == 1, let item = selected.first {
                    ItemDetails(item: item)
                } else if selected.count > 1 {
                    header(icon: FileIcons.icon(for: selected[0]), title: L10n.format("items.selected", selected.count))
                    let files = selected.filter { !$0.isNavigable }
                    if !files.isEmpty {
                        property(L10n.text("Size"), FileFormat.totalSize(files.reduce(0) { $0 + ($1.size ?? 0) }))
                    }
                } else if tab.isThisMac {
                    header(icon: FileIcons.icon(forPath: tab.url), title: tab.title)
                    property(L10n.text("Drives"), "\(VolumeMonitor.shared.volumes.count)")
                } else if tab.isNetwork {
                    header(icon: FileIcons.icon(forPath: tab.url), title: tab.title)
                } else if tab.isRecent {
                    header(icon: FileIcons.icon(forPath: tab.url), title: tab.title)
                    property(L10n.text("Items"), "\(tab.visibleItems.count)")
                } else {
                    header(icon: FileIcons.icon(forPath: tab.url), title: tab.title)
                    property(L10n.text("Items"), "\(tab.visibleItems.count)")
                    property(L10n.text("Location"), FileFormat.location(of: tab.url))
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.content.swiftUI)
    }
}

private struct ItemDetails: View {
    let item: FileItem
    @State private var dimensions: String?
    /// A copy taken out of the item's archive, for items inside archives.
    @State private var extracted: URL?

    /// The local file to preview: the item itself, or its copy.
    private var previewURL: URL? { item.url.isFileURL ? item.url : extracted }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if item.isNavigable || previewURL == nil {
                Image(nsImage: FileIcons.icon(for: item))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: 120)
            } else if FileKind.of(item.url, type: item.contentType) == .video {
                VideoPreview(url: previewURL!, autostarts: AppSettings.shared.autoplayPreviews)
                    .id(item.url)
                    .frame(maxWidth: .infinity)
                    .frame(height: 286)
            } else {
                QuickLookPreview(url: previewURL!, autostarts: AppSettings.shared.autoplayPreviews)
                    .id(item.url)
                    .frame(maxWidth: .infinity)
                    .frame(height: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            Text(item.name)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.text.swiftUI)
                .textSelection(.enabled)
            Text(item.localizedKind)
                .font(Theme.font)
                .foregroundStyle(Theme.secondaryText.swiftUI)
            Divider()
            Text(L10n.text("Properties"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.text.swiftUI)
            if !item.isNavigable { property(L10n.text("Size"), FileFormat.totalSize(item.size ?? 0)) }
            if let dimensions { property(L10n.text("Dimensions"), dimensions) }
            property(L10n.text("Date modified"), FileFormat.date(item.dateModified))
            property(L10n.text("Date created"), FileFormat.date(item.dateCreated))
            property(L10n.text("Location"), FileFormat.location(of: item.url))
        }
        .task(id: item.url) {
            extracted = item.url.isInArchive ? ArchivePreviews.shared.cachedFile(for: item.url) : nil
            if extracted == nil, item.url.isInArchive, !item.isDirectory, (item.size ?? 0) <= ArchivePreviews.automaticSizeLimit {
                extracted = await ArchivePreviews.shared.file(for: item.url)
            }
            dimensions = previewURL.flatMap(Self.imageDimensions)
        }
    }

    private static func imageDimensions(_ url: URL) -> String? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return "\(width) × \(height)"
    }
}

private func header(icon: NSImage, title: String) -> some View {
    VStack(alignment: .leading, spacing: 12) {
        Image(nsImage: icon)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 96, height: 96)
            .frame(maxWidth: .infinity)
        Text(title)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Theme.text.swiftUI)
    }
}

private func property(_ label: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
        Text(label)
            .font(.system(size: 11))
            .foregroundStyle(Theme.secondaryText.swiftUI)
        Text(value.isEmpty ? "—" : value)
            .font(Theme.font)
            .foregroundStyle(Theme.text.swiftUI)
            .textSelection(.enabled)
            .lineLimit(3)
            .truncationMode(.middle)
    }
}
