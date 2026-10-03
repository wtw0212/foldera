import SwiftUI

/// One explorer window, laid out like Windows 11 File Explorer.
struct ExplorerWindow: View {
    @State private var model = ExplorerWindowModel()
    @State private var settings = AppSettings.shared
    @State private var clipboard = FileClipboard.shared
    @State private var diskAccess = DiskAccess.shared
    @State private var swipe = SwipeFeedback()

    init(model: ExplorerWindowModel = ExplorerWindowModel(), settings: AppSettings = .shared, swipe: SwipeFeedback = SwipeFeedback()) {
        _model = State(initialValue: model)
        _settings = State(initialValue: settings)
        _swipe = State(initialValue: swipe)
    }

    var body: some View {
        let tab = model.activeTab
        VStack(spacing: 0) {
            TabStrip(model: model)

            VStack(spacing: 0) {
                AddressRow(model: model, tab: tab)
                Rectangle().fill(Theme.divider.swiftUI).frame(height: 1)
                CommandBar(model: model, tab: tab)
            }
            .background(Theme.layer.swiftUI)

            Rectangle().fill(Theme.divider.swiftUI).frame(height: 1)

            if diskAccess.showsBanner {
                FullDiskAccessBar(access: diskAccess)
            }

            HSplitView {
                if settings.showNavigationPane {
                    // Starts at its minimum width; drag the divider to widen it.
                    NavigationPane(model: model, tab: tab, settings: settings)
                        .frame(minWidth: 180, idealWidth: 180, maxWidth: 400)
                        .layoutPriority(0)
                }
                filePanes
                    .frame(minWidth: 320, maxWidth: .infinity)
                    .layoutPriority(1)
                if settings.sidePane == .details {
                    DetailsPane(tab: tab)
                        .frame(minWidth: 240, idealWidth: 320, maxWidth: 700)
                }
            }

            StatusBar(tab: tab)
        }
        .background(Theme.mica.swiftUI)
        .background(VisualEffectBackground())
        .background(
            NavigationGestures(
                feedback: swipe,
                back: { model.activeTab.goBack() },
                forward: { model.activeTab.goForward() },
                canGoBack: { model.activeTab.canGoBack },
                canGoForward: { model.activeTab.canGoForward }
            )
        )
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 720, minHeight: 420)
        .focusedSceneValue(\.explorer, model)
        .onAppear {
            TextFieldClickAway.install()
            model.offerWelcomeIfNeeded()
        }
        .sheet(item: $model.networkSheet) { sheet in
            switch sheet {
            case .connect(let address):
                ConnectServerSheet(model: model, address: address)
                    .environment(\.locale, L10n.locale)
            case .site(let site, let connect):
                SiteEditorSheet(site: site, connect: connect) { model.openSite($0) }
                    .environment(\.locale, L10n.locale)
            }
        }
        .sheet(isPresented: $model.isShowingWelcome) {
            WelcomeView { model.isShowingWelcome = false }
                .environment(\.locale, L10n.locale)
        }
        .sheet(isPresented: Binding(
            get: { tab.bulkRenameItems != nil },
            set: { if !$0 { tab.bulkRenameItems = nil } }
        )) {
            BulkRenameSheet(items: tab.bulkRenameItems ?? []) { renamed in
                tab.selection = Set(renamed.map(\.normalizedFileURL))
                tab.reload()
                tab.requestListFocus()
            }
        }
        .navigationTitle(tab.title)
    }

    /// One file pane, or two side by side in dual-pane mode.
    @ViewBuilder
    private var filePanes: some View {
        if model.isDualPane, let secondary = model.secondaryTab {
            HSplitView {
                dualPane(model.primaryTab, .primary)
                    .frame(minWidth: 240, maxWidth: .infinity)
                dualPane(secondary, .secondary)
                    .frame(minWidth: 240, maxWidth: .infinity)
            }
        } else {
            fileList(model.primaryTab, pane: .primary)
        }
    }

    private func dualPane(_ tab: BrowserTab, _ pane: ExplorerWindowModel.Pane) -> some View {
        let isFocused = model.focusedPane == pane
        return VStack(spacing: 0) {
            Button {
                model.focusedPane = pane
                tab.requestListFocus()
            } label: {
                HStack(spacing: 6) {
                    Image(nsImage: FileIcons.folder)
                        .resizable()
                        .frame(width: 14, height: 14)
                    Text(tab.title)
                        .font(.system(size: 11, weight: isFocused ? .semibold : .regular))
                        .foregroundStyle(isFocused ? Theme.text.swiftUI : Theme.secondaryText.swiftUI)
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 10)
                .frame(height: 24)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(Theme.layer.swiftUI)
            .overlay(alignment: .top) {
                Rectangle().fill(isFocused ? Theme.accent.swiftUI : .clear).frame(height: 2)
            }
            .help(tab.url.path)
            Rectangle().fill(Theme.divider.swiftUI).frame(height: 1)
            fileList(tab, pane: pane)
        }
    }

    private func fileList(_ tab: BrowserTab, pane: ExplorerWindowModel.Pane) -> some View {
        let onFocus = { if model.focusedPane != pane { model.focusedPane = pane } }
        return Group {
            if tab.isNetwork {
                NetworkView(model: model, tab: tab, onFocus: onFocus)
            } else if tab.isThisMac {
                ThisMacView(
                    tab: tab,
                    openInNewTab: { model.newTab(url: $0) },
                    openInBackgroundTab: { model.newTab(url: $0, activate: false) },
                    onFocus: onFocus
                )
            } else if tab.viewMode == .details {
                detailsList(tab, onFocus: onFocus)
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
                    openInNewTab: { model.newTab(url: $0) },
                    openInBackgroundTab: { model.newTab(url: $0, activate: false) },
                    onFocus: onFocus
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
        .overlay {
            // Back/forward navigate the active pane, so its arrow appears there rather than across both panes.
            if tab === model.activeTab {
                SwipeArrowOverlay(feedback: swipe).clipped()
            }
        }
    }

    private func detailsList(_ tab: BrowserTab, onFocus: @escaping () -> Void) -> some View {
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
            isSearchResults: tab.isSearchActive || tab.isRecent,
            openInNewTab: { model.newTab(url: $0) },
            openInBackgroundTab: { model.newTab(url: $0, activate: false) },
            onFocus: onFocus
        )
    }

    private func emptyMessage(_ tab: BrowserTab) -> String? {
        guard !tab.isPage else { return nil }
        if let error = tab.loadError { return error }
        guard !tab.isLoading, !tab.isSearching, tab.visibleItems.isEmpty else { return nil }
        if tab.isSearchActive { return L10n.text("No items match your search.") }
        return tab.isRecent ? L10n.text("Folders and files you open appear here.") : L10n.text("This folder is empty.")
    }
}

/// Explorer-style info bar offering Full Disk Access, so macOS stops asking folder by folder.
private struct FullDiskAccessBar: View {
    let access: DiskAccess

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(Theme.accent.swiftUI)
            Text(L10n.text("Give Foldera Full Disk Access so it can open every folder without asking. In Settings, drag Foldera (shown in Finder) into the list, or click + and choose it."))
                .lineLimit(2)
                .foregroundStyle(Theme.text.swiftUI)
            Spacer()
            Button(L10n.text("Open Settings")) { access.openSettings() }
                .buttonStyle(SubtleButtonStyle())
                .foregroundStyle(Theme.accent.swiftUI)
            Button {
                access.isBannerDismissed = true
            } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(SubtleButtonStyle(padding: EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4)))
            .help(L10n.text("Don't show again"))
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
            Text(tab.isThisMac ? L10n.format("drives.count", VolumeMonitor.shared.volumes.count)
                 : tab.isNetwork ? L10n.format("items.count", SFTPSites.shared.sites.count + NetworkBrowser.shared.servers.count)
                 : L10n.format("items.count", tab.visibleItems.count))
                .accessibilityIdentifier("item-count")
            if !tab.selection.isEmpty {
                separator
                Text(L10n.format("items.selected", tab.selection.count))
                if let size = selectedSize {
                    Text(FileFormat.totalSize(size)).padding(.leading, 8)
                }
            }
            Spacer()
            if tab.isSearching {
                Text(L10n.text("Searching…")).foregroundStyle(Theme.secondaryText.swiftUI).padding(.trailing, 6)
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
