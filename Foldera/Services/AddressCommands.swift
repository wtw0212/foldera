import AppKit

/// Commands typed in the address bar.
///
/// - `terminal`, `zsh`, `bash`, `sh`, `fish` open the terminal here; with arguments
///   (`terminal make`, `zsh -c 'make'`) they run that command here in Terminal.
/// - `code`, `cursor`, `zed`, `subl`, `xed` open the folder (or a named file) in that editor.
/// - `finder` (or `open .`) shows the folder in Finder.
/// - Any app name (`safari`, `Music`) launches it; any command on the PATH (`ls -la`, `git log`) runs in Terminal.
nonisolated enum AddressCommand {
    /// Terminal app choices for Settings, by bundle identifier.
    static let terminals: [(id: String, name: String)] = [
        ("com.apple.Terminal", "Terminal"),
        ("com.googlecode.iterm2", "iTerm"),
        ("com.mitchellh.ghostty", "Ghostty"),
        ("dev.warp.Warp-Stable", "Warp"),
        ("com.github.wez.wezterm", "WezTerm"),
        ("net.kovidgoyal.kitty", "kitty"),
        ("org.alacritty", "Alacritty"),
    ]

    private static let terminalAliases: Set<String> = ["terminal", "sh", "zsh", "bash", "fish"]
    /// Shells keep their name in the command (`bash script.sh`); the rest are just "open a terminal".
    private static let shells: Set<String> = ["sh", "zsh", "bash", "fish"]

    private static let editors: [String: [String]] = [
        "code": ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.vscodium"],
        "cursor": ["com.todesktop.230313mxl4e5"],
        "zed": ["dev.zed.Zed", "dev.zed.Zed-Preview"],
        "subl": ["com.sublimetext.4", "com.sublimetext.3"],
        "xed": ["com.apple.dt.Xcode"],
    ]

    /// Built-in commands (terminal, editors, Finder). Checked before relative paths.
    /// Returns false when `text` isn't one.
    @MainActor
    static func runBuiltIn(_ text: String, in folder: URL) -> Bool {
        let (command, arguments) = split(text)
        let name = command.lowercased()
        if terminalAliases.contains(name) {
            if arguments.isEmpty {
                openTerminal(at: folder)
            } else {
                runInTerminal(shells.contains(name) ? text : arguments, in: folder)
            }
            return true
        }
        if let bundleIDs = editors[name] {
            guard let app = bundleIDs.lazy.compactMap(NSWorkspace.shared.urlForApplication(withBundleIdentifier:)).first else {
                fail("“\(command)” isn’t installed.")
                return true
            }
            let target = arguments.isEmpty || arguments == "." ? folder : resolve(arguments, in: folder)
            NSWorkspace.shared.open([target], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                if let error { Task { @MainActor in BrowserTab.present(error) } }
            }
            return true
        }
        if (name == "finder" && arguments.isEmpty) || (name == "open" && arguments == ".") {
            NSWorkspace.shared.open(folder)
            return true
        }
        return false
    }

    /// Apps by name and PATH commands. Checked after paths, so a folder called "Music" wins over Music.app.
    @MainActor
    static func runFallback(_ text: String, in folder: URL) -> Bool {
        let (command, arguments) = split(text)
        if arguments.isEmpty, let app = application(named: text) {
            launch(app)
            return true
        }
        if executableOnPath(command) {
            runInTerminal(text, in: folder)
            return true
        }
        return false
    }

    // MARK: Terminal

    @MainActor
    static func openTerminal(at folder: URL) {
        let workspace = NSWorkspace.shared
        let preferred = AppSettings.shared.terminalApp
        guard let app = workspace.urlForApplication(withBundleIdentifier: preferred)
            ?? workspace.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        workspace.open([folder], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error { Task { @MainActor in BrowserTab.present(error) } }
        }
    }

    /// Runs `line` in a new Terminal window in `folder`, then leaves an interactive shell open there.
    /// Uses a self-deleting .command script, so no Apple Events permission is needed.
    @MainActor
    static func runInTerminal(_ line: String, in folder: URL) {
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("Foldera-\(UUID().uuidString).command")
        let contents = """
            #!/bin/zsh -l
            rm -f -- "$0"
            cd \(shellQuoted(folder.path)) || exit 1
            \(line)
            exec "${SHELL:-/bin/zsh}" -l

            """
        do {
            try contents.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        } catch {
            BrowserTab.present(error)
            return
        }
        // Terminal runs .command files; other terminals don't all do, so this always uses Terminal.
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        NSWorkspace.shared.open([script], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error { Task { @MainActor in BrowserTab.present(error) } }
        }
    }

    static func shellQuoted(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: Helpers

    /// "code src/app" → ("code", "src/app").
    static func split(_ text: String) -> (command: String, arguments: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let space = trimmed.firstIndex(of: " ") else { return (trimmed, "") }
        return (String(trimmed[..<space]), trimmed[space...].trimmingCharacters(in: .whitespaces))
    }

    private static func resolve(_ path: String, in folder: URL) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        return expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : folder.appendingPathComponent(expanded).standardizedFileURL
    }

    /// An installed app whose name matches, ignoring case ("safari" → Safari.app).
    static func application(named name: String) -> URL? {
        let wanted = name.lowercased().replacingOccurrences(of: ".app", with: "") + ".app"
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let folders = ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities", home + "/Applications"]
        for folder in folders {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
            if let match = names.first(where: { $0.lowercased() == wanted }) {
                return URL(fileURLWithPath: folder).appendingPathComponent(match)
            }
        }
        return nil
    }

    /// Apps launched from Finder don't get the login shell's PATH, so also check the usual places.
    static func executableOnPath(_ command: String) -> Bool {
        guard !command.isEmpty, !command.contains("/") else { return false }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["/usr/bin", "/bin", "/usr/sbin", "/sbin", "/usr/local/bin", "/opt/homebrew/bin", home + "/.local/bin", home + "/bin"]
        return path.contains { FileManager.default.isExecutableFile(atPath: $0 + "/" + command) }
    }

    @MainActor
    private static func launch(_ app: URL) {
        NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error { Task { @MainActor in BrowserTab.present(error) } }
        }
    }

    @MainActor
    private static func fail(_ message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}
