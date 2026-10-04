import SwiftUI

/// Back / Forward / Up / Refresh, the breadcrumb address bar and the search box.
struct AddressRow: View {
    @Bindable var model: ExplorerWindowModel
    let tab: BrowserTab

    var body: some View {
        HStack(spacing: 4) {
            IconButton(symbol: "arrow_left_regular", help: L10n.text("Back (⌘[)")) { tab.goBack() }
                .accessibilityIdentifier("navigate-back")
                .disabled(!tab.canGoBack)
                .contextMenu { historyMenu(tab.backHistory, back: true) }
            IconButton(symbol: "arrow_right_regular", help: L10n.text("Forward (⌘])")) { tab.goForward() }
                .accessibilityIdentifier("navigate-forward")
                .disabled(!tab.canGoForward)
                .contextMenu { historyMenu(tab.forwardHistory, back: false) }
            IconButton(symbol: "arrow_up_regular", help: L10n.format("Up to “%@” (⌘↑)", BrowserTab.pathName(of: tab.parentURL ?? tab.url))) {
                tab.goUp()
            }
            .disabled(!tab.canGoUp)
            .accessibilityIdentifier("navigate-up")
            IconButton(symbol: "arrow_clockwise_regular", help: L10n.text("Refresh (⌘R)")) { tab.reload() }
                .padding(.trailing, 4)

            AddressBar(model: model, tab: tab)
            SearchBox(model: model, tab: tab)
                .frame(width: 260)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func historyMenu(_ urls: [URL], back: Bool) -> some View {
        ForEach(Array(urls.prefix(15).enumerated()), id: \.offset) { _, url in
            Button(BrowserTab.pathName(of: url)) { tab.jump(toHistory: url, back: back) }
        }
    }
}

// MARK: - Address bar

private struct AddressBar: View {
    @Bindable var model: ExplorerWindowModel
    let tab: BrowserTab

    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        ZStack(alignment: .leading) {
            if model.isEditingAddress {
                TextField("", text: $text)
                    .accessibilityIdentifier("address-field")
                    .textFieldStyle(.plain)
                    .font(Theme.font)
                    .focused($isFocused)
                    .padding(.horizontal, 8)
                    .onSubmit(commit)
                    .onExitCommand(perform: cancel)
                    .onChange(of: isFocused) { _, focused in
                        if !focused { cancel() }
                    }
                    .onAppear {
                        text = BrowserTab.editableAddress(of: tab.url)
                        // Focus once the field is in the window; setting it during onAppear can lose to
                        // the search box. Then select the whole path, like Explorer.
                        DispatchQueue.main.async {
                            isFocused = true
                            DispatchQueue.main.async { NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil) }
                        }
                    }
            } else {
                Breadcrumbs(model: model, tab: tab)
                    .padding(.leading, 6)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 32, maxHeight: 32, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(Theme.controlFill.swiftUI)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(model.isEditingAddress ? Theme.accent.swiftUI : Theme.controlStroke.swiftUI, lineWidth: 1)
        )
        .overlay(alignment: .bottom) {
            if model.isEditingAddress {
                Rectangle().fill(Theme.accent.swiftUI).frame(height: 2).padding(.horizontal, 1)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.isEditingAddress = true }
    }

    /// Like Explorer's address bar: a path (absolute, ~, or relative to this folder), a web address,
    /// a server address, or a command (see `AddressCommand`).
    private func commit() {
        let input = text.trimmingCharacters(in: .whitespaces)
        model.isEditingAddress = false
        guard !input.isEmpty else { return }
        if input.lowercased() == "this mac" || input == L10n.text("This Mac") {
            tab.navigate(to: BrowserTab.thisMacURL)
            return
        }
        if input.lowercased() == "network" || input == L10n.text("Network") {
            tab.navigate(to: BrowserTab.networkURL)
            return
        }
        if input.lowercased() == "recent" || input == L10n.text("Recent") {
            tab.navigate(to: BrowserTab.recentURL)
            return
        }
        if input.contains("://") || input.lowercased().hasPrefix("mailto:"), let url = URL(string: input) {
            // sftp:// opens here, smb://, afp:// and nfs:// mount; https://… and mailto: open in their apps.
            if model.openServerAddress(input, in: tab) { return }
            NSWorkspace.shared.open(url)
            return
        }
        if let endpoint = tab.url.remoteEndpoint {
            // On a server, paths are the server's: absolute, or relative to this folder.
            let path = input.hasPrefix("/") ? input : RemotePath.join(tab.url.remotePath, input)
            tab.navigate(to: endpoint.url(path: path))
            tab.requestListFocus()
            return
        }
        let expanded = (input as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            if !openPath(expanded) { notFound(input) }
            return
        }
        if AddressCommand.runBuiltIn(input, in: tab.url) { return }
        if openPath(tab.url.appendingPathComponent(expanded).standardizedFileURL.path) { return }
        if AddressCommand.runFallback(input, in: tab.url) { return }
        notFound(input)
    }

    /// Opens a folder here, or a file in its app. False when nothing is at `path`.
    private func openPath(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return false }
        let url = URL(fileURLWithPath: path)
        if isDirectory.boolValue {
            tab.navigate(to: url)
        } else {
            NSWorkspace.shared.open(url)
        }
        tab.requestListFocus()
        return true
    }

    private func notFound(_ input: String) {
        let alert = NSAlert()
        alert.messageText = L10n.format("Foldera can’t find “%@”.", input)
        alert.informativeText = L10n.text("Check the spelling and try again.")
        alert.alertStyle = .warning
        alert.runModal()
    }

    private func cancel() {
        model.isEditingAddress = false
    }
}

struct Breadcrumbs: View {
    let model: ExplorerWindowModel
    let tab: BrowserTab

    var body: some View {
        let segments = Self.segments(for: tab.url)
        HStack(spacing: 0) {
            Image(nsImage: FileIcons.icon(forPath: tab.url))
                .resizable()
                .frame(width: 16, height: 16)
                .padding(.trailing, 2)
            ViewThatFits(in: .horizontal) {
                ForEach(0..<segments.count, id: \.self) { dropped in
                    HStack(spacing: 0) {
                        if dropped > 0 {
                            OverflowButton(hidden: Array(segments.prefix(dropped)), tab: tab)
                        }
                        ForEach(segments.dropFirst(dropped), id: \.self) { url in
                            Segment(model: model, url: url, tab: tab)
                        }
                    }
                    .fixedSize()
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// The location's folders from This Mac down, e.g. This Mac › Macintosh HD › Users › me › Documents.
    static func segments(for url: URL) -> [URL] {
        guard url != BrowserTab.thisMacURL, url != BrowserTab.networkURL, url != BrowserTab.recentURL else { return [url] }
        if let endpoint = url.remoteEndpoint {
            var result = [endpoint.root]
            var path = ""
            for component in url.remotePath.split(separator: "/") {
                path += "/" + component
                result.append(endpoint.url(path: path))
            }
            return [BrowserTab.networkURL] + result
        }
        let volume = (try? url.resourceValues(forKeys: [.volumeURLKey]).volume) ?? URL(fileURLWithPath: "/")
        var result: [URL] = []
        var current = url.standardizedFileURL
        while true {
            result.append(current)
            if current.path == volume.standardizedFileURL.path || current.path == "/" { break }
            current = current.deletingLastPathComponent()
        }
        return [BrowserTab.thisMacURL] + result.reversed()
    }
}

private struct Segment: View {
    let model: ExplorerWindowModel
    let url: URL
    let tab: BrowserTab

    var body: some View {
        HStack(spacing: 0) {
            Button(BrowserTab.pathName(of: url)) {
                tab.navigate(to: url)
            }
            .buttonStyle(SubtleButtonStyle(padding: EdgeInsets(top: 4, leading: 6, bottom: 4, trailing: 6)))
            .folderDropTarget(url)
            .onMiddleClick { model.newTab(url: url, activate: false) }

            Button {
                if url.isRemote || url == BrowserTab.networkURL {
                    Task { popUpMenu(await SubfolderMenu.make(forServerLocation: url, model: model, tab: tab)) }
                } else {
                    popUpMenu(SubfolderMenu.make(for: url, tab: tab))
                }
            } label: {
                AppIcon(name: "chevron_right_regular", size: 12)
                    .foregroundStyle(Theme.secondaryText.swiftUI)
            }
            .buttonStyle(SubtleButtonStyle(padding: EdgeInsets(top: 6, leading: 4, bottom: 6, trailing: 4)))
            .hint(L10n.format("Show folders in “%@”", BrowserTab.pathName(of: url)))
        }
    }
}

private struct OverflowButton: View {
    let hidden: [URL]
    let tab: BrowserTab

    var body: some View {
        Button {
            let menu = NSMenu()
            for url in hidden.reversed() {
                let item = ClosureMenuItem(BrowserTab.pathName(of: url), image: FileIcons.folder) { tab.navigate(to: url) }
                menu.addItem(item)
            }
            popUpMenu(menu)
        } label: {
            Image(systemName: "chevron.left.2")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Theme.secondaryText.swiftUI)
        }
        .buttonStyle(SubtleButtonStyle(padding: EdgeInsets(top: 6, leading: 4, bottom: 6, trailing: 4)))
        .hint(L10n.text("Show the rest of the path"))
    }
}

/// Lists the subfolders of a folder, built when the chevron is clicked.
enum SubfolderMenu {
    /// Network lists sites and network drives; a server folder lists its subfolders (fetched from the server).
    static func make(forServerLocation url: URL, model: ExplorerWindowModel, tab: BrowserTab,
                     sites: SFTPSites = .shared, connections: RemoteConnections = .shared) async -> NSMenu {
        let menu = NSMenu()
        let icon = FileIcons.network.copy() as? NSImage
        icon?.size = NSSize(width: 16, height: 16)
        if url == BrowserTab.networkURL {
            for site in sites.sites {
                menu.addItem(ClosureMenuItem(site.title, image: icon) { model.openSite(site, in: tab) })
            }
            for volume in VolumeMonitor.shared.networkVolumes {
                menu.addItem(ClosureMenuItem(volume.title, image: icon) { tab.navigate(to: volume.url) })
            }
        } else if let endpoint = url.remoteEndpoint {
            let showHidden = AppSettings.shared.showHiddenFiles
            let entries = (try? await connections.read(endpoint) { try await $0.list(url.remotePath) }) ?? []
            let folders = entries
                .filter { $0.isDirectory && (showHidden || !$0.name.hasPrefix(".")) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            for folder in folders {
                let target = endpoint.url(path: folder.path)
                let item = ClosureMenuItem(folder.name, image: FileIcons.folder) { tab.navigate(to: target) }
                if RemotePath.isWithin(tab.url.remotePath, folder.path), tab.url.remoteEndpoint == endpoint {
                    let bold = NSFontManager.shared.convert(.menuFont(ofSize: 0), toHaveTrait: .boldFontMask)
                    item.attributedTitle = NSAttributedString(string: item.title, attributes: [.font: bold])
                }
                menu.addItem(item)
            }
        }
        if menu.items.isEmpty {
            let empty = NSMenuItem(title: L10n.text(url == BrowserTab.networkURL ? "No servers" : "No subfolders"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        return menu
    }

    static func make(for url: URL, tab: BrowserTab) -> NSMenu {
        let menu = NSMenu()
        if url == BrowserTab.thisMacURL {
            for volume in VolumeMonitor.shared.volumes {
                let icon = FileIcons.icon(forPath: volume.url).copy() as? NSImage
                icon?.size = NSSize(width: 16, height: 16)
                menu.addItem(ClosureMenuItem(BrowserTab.pathName(of: volume.url), image: icon) { tab.navigate(to: volume.url) })
            }
            return menu
        }
        let showHidden = AppSettings.shared.showHiddenFiles
        let children = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey, .isHiddenKey],
            options: showHidden ? [] : [.skipsHiddenFiles]
        )) ?? []
        let folders = children
            .filter { child in
                let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
                return values?.isDirectory == true && values?.isPackage != true
            }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        if folders.isEmpty {
            let empty = NSMenuItem(title: L10n.text("No subfolders"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        let image = FileIcons.folder
        for folder in folders {
            let item = ClosureMenuItem(BrowserTab.pathName(of: folder), image: image) {
                tab.navigate(to: folder)
            }
            if tab.url.path.hasPrefix(folder.path + "/") || tab.url == folder.normalizedFileURL {
                let bold = NSFontManager.shared.convert(.menuFont(ofSize: 0), toHaveTrait: .boldFontMask)
                item.attributedTitle = NSAttributedString(string: item.title, attributes: [.font: bold])
            }
            menu.addItem(item)
        }
        return menu
    }
}

// MARK: - Search

private struct SearchBox: View {
    let model: ExplorerWindowModel
    @Bindable var tab: BrowserTab
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            TextField(L10n.format("Search %@", tab.title), text: $tab.searchText)
                .accessibilityIdentifier("search-field")
                .textFieldStyle(.plain)
                .font(Theme.font)
                .focused($isFocused)
                .disabled(tab.isPage) // nothing to search on the drives and network pages
                .onExitCommand {
                    tab.searchText = ""
                    tab.requestListFocus()
                }
                .onSubmit { tab.requestListFocus() }
            if tab.searchText.isEmpty {
                AppIcon(name: "search_regular", size: 14)
                    .foregroundStyle(Theme.secondaryText.swiftUI)
            } else {
                Button {
                    tab.searchText = ""
                } label: {
                    AppIcon(name: "dismiss_regular", size: 12)
                }
                .buttonStyle(SubtleButtonStyle(padding: EdgeInsets(top: 3, leading: 3, bottom: 3, trailing: 3)))
                .hint(L10n.text("Clear search"))
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 4).fill(Theme.controlFill.swiftUI))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(isFocused ? Theme.accent.swiftUI : Theme.controlStroke.swiftUI, lineWidth: 1)
        )
        .onChange(of: model.focusSearchToken) { isFocused = true }
    }
}
