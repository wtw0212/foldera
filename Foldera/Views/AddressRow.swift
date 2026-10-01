import SwiftUI

/// Back / Forward / Up / Refresh, the breadcrumb address bar and the search box.
struct AddressRow: View {
    @Bindable var model: ExplorerWindowModel
    let tab: BrowserTab

    var body: some View {
        HStack(spacing: 4) {
            IconButton(symbol: "arrow.left", help: "Back (⌘[)") { tab.goBack() }
                .disabled(!tab.canGoBack)
                .contextMenu { historyMenu(tab.backHistory, back: true) }
            IconButton(symbol: "arrow.right", help: "Forward (⌘])") { tab.goForward() }
                .disabled(!tab.canGoForward)
                .contextMenu { historyMenu(tab.forwardHistory, back: false) }
            IconButton(symbol: "arrow.up", help: "Up to “\(BrowserTab.displayName(of: tab.url.deletingLastPathComponent()))” (⌘↑)") {
                tab.goUp()
            }
            .disabled(!tab.canGoUp)
            IconButton(symbol: "arrow.clockwise", help: "Refresh (⌘R)") { tab.reload() }
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
            Button(BrowserTab.displayName(of: url)) { tab.jump(toHistory: url, back: back) }
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
                        text = tab.url.path
                        isFocused = true
                    }
            } else {
                Breadcrumbs(tab: tab)
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

    private func commit() {
        let path = (text.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        model.isEditingAddress = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            let alert = NSAlert()
            alert.messageText = "Foldera can’t find “\(text)”."
            alert.informativeText = "Check the spelling and try again."
            alert.alertStyle = .warning
            alert.runModal()
            return
        }
        let url = URL(fileURLWithPath: path)
        if isDirectory.boolValue {
            tab.navigate(to: url)
        } else {
            NSWorkspace.shared.open(url)
        }
        tab.requestListFocus()
    }

    private func cancel() {
        model.isEditingAddress = false
    }
}

private struct Breadcrumbs: View {
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
                            Segment(url: url, tab: tab)
                        }
                    }
                    .fixedSize()
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// The location's folders from the volume root down, e.g. Macintosh HD › Users › me › Documents.
    static func segments(for url: URL) -> [URL] {
        let volume = (try? url.resourceValues(forKeys: [.volumeURLKey]).volume) ?? URL(fileURLWithPath: "/")
        var result: [URL] = []
        var current = url.standardizedFileURL
        while true {
            result.append(current)
            if current.path == volume.standardizedFileURL.path || current.path == "/" { break }
            current = current.deletingLastPathComponent()
        }
        return result.reversed()
    }
}

private struct Segment: View {
    let url: URL
    let tab: BrowserTab

    var body: some View {
        HStack(spacing: 0) {
            Button(BrowserTab.displayName(of: url)) {
                tab.navigate(to: url)
            }
            .buttonStyle(SubtleButtonStyle(padding: EdgeInsets(top: 4, leading: 6, bottom: 4, trailing: 6)))
            .folderDropTarget(url)

            Button {
                popUpMenu(SubfolderMenu.make(for: url, tab: tab))
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.secondaryText.swiftUI)
            }
            .buttonStyle(SubtleButtonStyle(padding: EdgeInsets(top: 6, leading: 4, bottom: 6, trailing: 4)))
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
                let item = ClosureMenuItem(BrowserTab.displayName(of: url), image: FileIcons.folder) { tab.navigate(to: url) }
                menu.addItem(item)
            }
            popUpMenu(menu)
        } label: {
            Image(systemName: "chevron.left.2")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Theme.secondaryText.swiftUI)
        }
        .buttonStyle(SubtleButtonStyle(padding: EdgeInsets(top: 6, leading: 4, bottom: 6, trailing: 4)))
    }
}

/// Lists the subfolders of a folder, built when the chevron is clicked.
enum SubfolderMenu {
    static func make(for url: URL, tab: BrowserTab) -> NSMenu {
        let menu = NSMenu()
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
            let empty = NSMenuItem(title: "No subfolders", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        let image = FileIcons.folder
        for folder in folders {
            let item = ClosureMenuItem(FileManager.default.displayName(atPath: folder.path), image: image) {
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
            TextField("Search \(tab.title)", text: $tab.searchText)
                .textFieldStyle(.plain)
                .font(Theme.font)
                .focused($isFocused)
                .onExitCommand {
                    tab.searchText = ""
                    tab.requestListFocus()
                }
                .onSubmit { tab.requestListFocus() }
            if tab.searchText.isEmpty {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText.swiftUI)
            } else {
                Button {
                    tab.searchText = ""
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(SubtleButtonStyle(padding: EdgeInsets(top: 3, leading: 3, bottom: 3, trailing: 3)))
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
