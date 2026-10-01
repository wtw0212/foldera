import SwiftUI

/// One explorer window, laid out like Windows 11 File Explorer.
struct ExplorerWindow: View {
    @State private var model = ExplorerWindowModel()
    @State private var settings = AppSettings.shared
    @State private var clipboard = FileClipboard.shared

    var body: some View {
        let tab = model.activeTab
        VStack(spacing: 0) {
            TabStrip(model: model)

            VStack(spacing: 0) {
                AddressRow(model: model, tab: tab)
                Rectangle().fill(Theme.divider.swiftUI).frame(height: 1)
                CommandBar(tab: tab)
            }
            .background(Theme.layer.swiftUI)

            Rectangle().fill(Theme.divider.swiftUI).frame(height: 1)

            HSplitView {
                if settings.showNavigationPane {
                    NavigationPane(model: model, tab: tab)
                        .frame(minWidth: 160, idealWidth: 220, maxWidth: 400)
                }
                fileList(tab)
                    .frame(minWidth: 320, maxWidth: .infinity)
            }

            StatusBar(tab: tab)
        }
        .background(Theme.mica.swiftUI)
        .background(VisualEffectBackground())
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 720, minHeight: 420)
        .focusedSceneValue(\.explorer, model)
        .navigationTitle(tab.title)
    }

    private func fileList(_ tab: BrowserTab) -> some View {
        FileListView(
            tab: tab,
            items: tab.visibleItems,
            selection: tab.selection,
            sort: tab.sort,
            showExtensions: settings.showExtensions,
            rowHeight: settings.rowHeight,
            cutURLs: clipboard.cutURLs,
            renameRequest: tab.renameRequest,
            focusToken: tab.focusListToken,
            isSearchResults: tab.isSearchActive,
            openInNewTab: { model.newTab(url: $0) }
        )
        .overlay(alignment: .top) {
            if let message = emptyMessage(tab) {
                Text(message)
                    .font(Theme.font)
                    .foregroundStyle(Theme.secondaryText.swiftUI)
                    .multilineTextAlignment(.center)
                    .padding(.top, 48)
                    .padding(.horizontal, 24)
                    .allowsHitTesting(false)
            }
        }
    }

    private func emptyMessage(_ tab: BrowserTab) -> String? {
        if let error = tab.loadError { return error }
        guard !tab.isLoading, !tab.isSearching, tab.visibleItems.isEmpty else { return nil }
        return tab.isSearchActive ? "No items match your search." : "This folder is empty."
    }
}

/// "N items | M items selected  X KB" footer.
private struct StatusBar: View {
    let tab: BrowserTab

    var body: some View {
        HStack(spacing: 0) {
            Text(countText(tab.visibleItems.count))
            if !tab.selection.isEmpty {
                separator
                Text("\(countText(tab.selection.count)) selected")
                if let size = selectedSize {
                    Text(FileFormat.totalSize(size)).padding(.leading, 8)
                }
            }
            Spacer()
            if tab.isSearching {
                Text("Searching…").foregroundStyle(Theme.secondaryText.swiftUI).padding(.trailing, 6)
            }
            if tab.isLoading || tab.isSearching {
                ProgressView().controlSize(.mini).padding(.trailing, 8)
            }
        }
        .font(Theme.font)
        .foregroundStyle(Theme.text.swiftUI)
        .padding(.horizontal, 14)
        .frame(height: 26)
        .background(Theme.content.swiftUI)
    }

    private var separator: some View {
        Rectangle()
            .fill(Theme.divider.swiftUI)
            .frame(width: 1, height: 14)
            .padding(.horizontal, 10)
    }

    private func countText(_ count: Int) -> String {
        count == 1 ? "1 item" : "\(count) items"
    }

    /// Explorer only shows a size when the selection is files only.
    private var selectedSize: Int64? {
        let selected = tab.selectedItems
        guard !selected.isEmpty, selected.allSatisfy({ !$0.isNavigable }) else { return nil }
        return selected.reduce(0) { $0 + ($1.size ?? 0) }
    }
}

/// Behind-window blur under the Mica tint.
private struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
