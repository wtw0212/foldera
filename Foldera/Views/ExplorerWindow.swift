import SwiftUI

/// One explorer window, laid out like Windows 11 File Explorer.
struct ExplorerWindow: View {
    @State private var model = ExplorerWindowModel()
    @State private var settings = AppSettings.shared
    @State private var clipboard = FileClipboard.shared
    @State private var diskAccess = DiskAccess.shared

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

            if diskAccess.showsBanner {
                FullDiskAccessBar(access: diskAccess)
            }

            HSplitView {
                if settings.showNavigationPane {
                    // Starts at its minimum width; drag the divider to widen it.
                    NavigationPane(model: model, tab: tab)
                        .frame(minWidth: 180, idealWidth: 180, maxWidth: 400)
                        .layoutPriority(0)
                }
                fileList(tab)
                    .frame(minWidth: 320, maxWidth: .infinity)
                    .layoutPriority(1)
                switch settings.sidePane {
                case .preview:
                    PreviewPane(tab: tab)
                        .frame(minWidth: 220, idealWidth: 320, maxWidth: 700)
                case .details:
                    DetailsPane(tab: tab)
                        .frame(minWidth: 220, idealWidth: 280, maxWidth: 500)
                case .none:
                    EmptyView()
                }
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
        Group {
            if tab.viewMode == .details {
                detailsList(tab)
            } else {
                FileGridView(
                    tab: tab,
                    mode: tab.viewMode,
                    items: tab.visibleItems,
                    selection: tab.selection,
                    showExtensions: settings.showExtensions,
                    cutURLs: clipboard.cutURLs,
                    renameRequest: tab.renameRequest,
                    focusToken: tab.focusListToken,
                    openInNewTab: { model.newTab(url: $0) }
                )
            }
        }
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

    private func detailsList(_ tab: BrowserTab) -> some View {
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
    }

    private func emptyMessage(_ tab: BrowserTab) -> String? {
        if let error = tab.loadError { return error }
        guard !tab.isLoading, !tab.isSearching, tab.visibleItems.isEmpty else { return nil }
        return tab.isSearchActive ? "No items match your search." : "This folder is empty."
    }
}

/// Explorer-style info bar offering Full Disk Access, so macOS stops asking folder by folder.
private struct FullDiskAccessBar: View {
    let access: DiskAccess

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(Theme.accent.swiftUI)
            Text("Give Foldera Full Disk Access so it can open every folder without asking each time.")
                .foregroundStyle(Theme.text.swiftUI)
            Spacer()
            Button("Open Settings") { access.openSettings() }
                .buttonStyle(SubtleButtonStyle())
                .foregroundStyle(Theme.accent.swiftUI)
            Button {
                access.isBannerDismissed = true
            } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(SubtleButtonStyle(padding: EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4)))
            .help("Don't show again")
        }
        .font(Theme.font)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Theme.selection.swiftUI.opacity(0.6))
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
            layoutButton(.details, tab: tab)
            layoutButton(.largeIcons, tab: tab)
        }
        .font(Theme.font)
        .foregroundStyle(Theme.text.swiftUI)
        .padding(.horizontal, 14)
        .frame(height: 26)
        .background(Theme.content.swiftUI)
    }

    /// The two layout toggles at the right of Explorer's status bar.
    private func layoutButton(_ mode: ViewMode, tab: BrowserTab) -> some View {
        Button {
            tab.viewMode = mode
        } label: {
            Image(systemName: mode.symbol)
                .font(.system(size: 12))
                .frame(width: 16, height: 14)
        }
        .buttonStyle(SubtleButtonStyle(padding: EdgeInsets(top: 3, leading: 4, bottom: 3, trailing: 4)))
        .background(RoundedRectangle(cornerRadius: 4).fill(tab.viewMode == mode ? Theme.selection.swiftUI : .clear))
        .help(mode.title)
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
