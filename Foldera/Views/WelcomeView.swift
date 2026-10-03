import SwiftUI

/// First-launch introduction: language, the main features, and Full Disk Access.
/// Shown once; Help ▸ Welcome to Foldera brings it back.
struct WelcomeView: View {
    let onFinish: () -> Void

    @State private var settings = AppSettings.shared
    @State private var access = DiskAccess.shared
    @State private var page = 0
    @Environment(\.openSettings) private var openSettings

    private let pageCount = 3

    init(page: Int = 0, onFinish: @escaping () -> Void) {
        _page = State(initialValue: page)
        self.onFinish = onFinish
    }

    /// Set once the user has finished or skipped the introduction.
    static let seenKey = "hasSeenWelcome"
    static var hasBeenSeen: Bool { UserDefaults.standard.bool(forKey: seenKey) }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch page {
                case 0: welcomePage
                case 1: featuresPage
                default: accessPage
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 36)
            .padding(.top, 32)

            footer
        }
        .frame(width: 560, height: 470)
        .background(Theme.content.swiftUI)
    }

    // MARK: Pages

    private var welcomePage: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text(L10n.text("Welcome to Foldera"))
                .font(.system(size: 26, weight: .semibold))
            Text(L10n.text("A Windows-style file explorer for your Mac: tabs, a navigation pane, an address bar you can type in, and Mac shortcuts."))
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondaryText.swiftUI)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Picker(L10n.text("Language:"), selection: $settings.language) {
                ForEach(AppLanguage.allCases) { Text($0.title).tag($0) }
            }
            .frame(width: 260)
            .padding(.top, 10)
        }
    }

    private var featuresPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.text("A quick tour"))
                .font(.system(size: 20, weight: .semibold))
            feature("rectangle.split.2x1", L10n.text("Tabs and dual pane"),
                    L10n.text("⌘T opens a tab, middle-click opens a folder in the background, ⌥⌘D shows two panes side by side."))
            feature("character.cursor.ibeam", L10n.text("Address bar"),
                    L10n.text("Click the path to type a location, or a command such as “terminal” or “code”."))
            feature("doc.zipper", L10n.text("Archives"),
                    L10n.text("Right-click to extract zip, 7z and rar files, or compress anything to ZIP or 7z."))
            feature("pencil.and.list.clipboard", L10n.text("Bulk rename"),
                    L10n.text("Select several items and press F2 to rename them all at once."))
            feature("externaldrive", L10n.text("This Mac and cloud drives"),
                    L10n.text("See every drive’s free space, and OneDrive, Google Drive or Dropbox in the navigation pane."))
        }
    }

    private var accessPage: some View {
        VStack(spacing: 14) {
            Image(systemName: access.hasFullDiskAccess ? "checkmark.shield.fill" : "lock.shield")
                .font(.system(size: 54))
                .foregroundStyle(access.hasFullDiskAccess ? Color.green : Theme.accent.swiftUI)
            Text(L10n.text("Full Disk Access"))
                .font(.system(size: 20, weight: .semibold))
            Text(access.hasFullDiskAccess
                 ? L10n.text("Foldera can open every folder without asking. You’re all set.")
                 : L10n.text("Without it, macOS asks for permission folder by folder. Turn on Foldera in Privacy & Security ▸ Full Disk Access, then reopen Foldera."))
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondaryText.swiftUI)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if !access.hasFullDiskAccess {
                Button(L10n.text("Open Privacy & Security Settings")) { access.openSettings() }
                    .controlSize(.large)
            }
            Button(L10n.text("Open Foldera Settings…")) { openSettings() }
                .buttonStyle(.link)
                .padding(.top, 6)
        }
    }

    private func feature(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 20))
                .foregroundStyle(Theme.accent.swiftUI)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText.swiftUI)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Button(L10n.text("Skip"), action: finish)
                .buttonStyle(.link)
                .opacity(page < pageCount - 1 ? 1 : 0)
            Spacer()
            HStack(spacing: 6) {
                ForEach(0..<pageCount, id: \.self) { index in
                    Circle()
                        .fill(index == page ? Theme.accent.swiftUI : Theme.divider.swiftUI)
                        .frame(width: 7, height: 7)
                }
            }
            Spacer()
            if page > 0 {
                Button(L10n.text("Back")) { page -= 1 }
            }
            if page < pageCount - 1 {
                Button(L10n.text("Next")) { page += 1 }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button(L10n.text("Get Started"), action: finish)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Theme.layer.swiftUI)
        .overlay(alignment: .top) { Rectangle().fill(Theme.divider.swiftUI).frame(height: 1) }
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: Self.seenKey)
        onFinish()
    }
}
