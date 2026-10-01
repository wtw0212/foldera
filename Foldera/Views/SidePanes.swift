import ImageIO
import Quartz
import SwiftUI

private struct QuickLookPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.shouldCloseWithWindow = false
        view.autostarts = true
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
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
                    header(icon: FileIcons.icon(for: selected[0]), title: "\(selected.count) items selected")
                    let files = selected.filter { !$0.isNavigable }
                    if !files.isEmpty {
                        property("Size", FileFormat.totalSize(files.reduce(0) { $0 + ($1.size ?? 0) }))
                    }
                } else {
                    header(icon: FileIcons.icon(forPath: tab.url), title: tab.title)
                    property("Items", "\(tab.visibleItems.count)")
                    property("Location", (tab.url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if item.isNavigable {
                Image(nsImage: FileIcons.icon(for: item))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: 120)
            } else {
                QuickLookPreview(url: item.url)
                    .id(item.url)
                    .frame(maxWidth: .infinity)
                    .frame(height: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            Text(item.name)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.text.swiftUI)
                .textSelection(.enabled)
            Text(item.kind)
                .font(Theme.font)
                .foregroundStyle(Theme.secondaryText.swiftUI)
            Divider()
            Text("Properties")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.text.swiftUI)
            if !item.isNavigable { property("Size", FileFormat.totalSize(item.size ?? 0)) }
            if let dimensions { property("Dimensions", dimensions) }
            property("Date modified", FileFormat.date(item.dateModified))
            property("Date created", FileFormat.date(item.dateCreated))
            property("Location", FileFormat.location(of: item.url))
        }
        .task(id: item.url) {
            dimensions = Self.imageDimensions(item.url)
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
