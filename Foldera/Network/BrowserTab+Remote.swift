import AppKit

/// Folder commands for sftp:// tabs. Server changes can't be undone (there's no Trash on the server).
extension BrowserTab {
    /// Asks before deleting; replaced in tests.
    static var confirmRemoteDelete: @MainActor ([String]) -> Bool = BrowserTab.askToDeleteRemotely

    func remoteNewItem(named name: String, folder: Bool) {
        runRemote { system, directory in
            let path = try await system.uniquePath(named: name, in: directory)
            if folder {
                try await system.makeDirectory(path)
            } else {
                try await system.createFile(path)
            }
            return path
        } then: { endpoint, path in
            self.beginRename(endpoint.url(path: path))
        }
    }

    func remoteRename(_ url: URL, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != ".", trimmed != "..", !trimmed.contains("/"), !trimmed.contains("\0") else {
            Self.present(FileOperations.OperationError.invalidName(newName))
            return
        }
        let source = url.remotePath
        let destination = RemotePath.join(RemotePath.parent(of: source), trimmed)
        runRemote { system, _ in
            if try await system.entry(at: destination) != nil { throw RemoteError.alreadyExists(trimmed) }
            try await system.rename(source, to: destination)
            return destination
        } then: { endpoint, path in
            self.selection = [endpoint.url(path: path)]
        }
    }

    func remoteDeleteSelection() {
        let items = selectedItems
        guard !items.isEmpty, Self.confirmRemoteDelete(items.map(\.name)) else { return }
        runRemote { system, _ in
            for item in items {
                if let entry = try await system.unfollowedEntry(at: item.url.remotePath) {
                    try await system.removeRecursively(entry)
                }
            }
            return ""
        } then: { _, _ in
            self.selection = []
        }
    }

    func remoteOpen(_ url: URL) {
        Task {
            do {
                try await RemoteEditing.shared.open(url)
            } catch is CancellationError {
            } catch {
                Self.present(error)
            }
        }
    }

    /// Opens Terminal with `ssh` signed in to this server, in this folder.
    func remoteOpenInTerminal(sites: SFTPSites = .shared) {
        guard let endpoint = url.remoteEndpoint else { return }
        AddressCommand.runInTerminal(Self.sshCommand(for: endpoint, path: url.remotePath, site: sites.site(for: endpoint)),
                                     in: FileManager.default.homeDirectoryForCurrentUser)
    }

    static func sshCommand(for endpoint: RemoteEndpoint, path: String, site: SFTPSite?) -> String {
        var command = ["ssh", "-t"]
        if endpoint.port != RemoteEndpoint.defaultPort { command += ["-p", String(endpoint.port)] }
        if let site, site.authentication == .privateKey { command += ["-i", AddressCommand.shellQuoted(site.expandedKeyPath)] }
        let remote = "cd \(AddressCommand.shellQuoted(path)) && exec \"$SHELL\" -l"
        command += [AddressCommand.shellQuoted("\(endpoint.username)@\(endpoint.host)"), AddressCommand.shellQuoted(remote)]
        return command.joined(separator: " ")
    }

    /// A summary alert: SFTP has no Get Info window to hand off to.
    func remoteShowProperties() {
        let targets = hasSelection ? selectedItems : []
        let alert = NSAlert()
        if targets.count == 1, let item = targets.first {
            alert.messageText = item.name
            alert.informativeText = Self.remoteDetails(item, location: url)
        } else if targets.isEmpty {
            alert.messageText = title
            alert.informativeText = L10n.format("Location: %@", url.remoteEndpoint.map { "\($0.displayName):\(url.remotePath)" } ?? url.absoluteString)
        } else {
            alert.messageText = L10n.format("items.selected", targets.count)
            let bytes = targets.compactMap(\.size).reduce(0, +)
            alert.informativeText = L10n.format("Size: %@", ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
        }
        alert.runModal()
    }

    static func remoteDetails(_ item: FileItem, location: URL) -> String {
        var lines = [L10n.format("Location: %@", location.remoteEndpoint.map { "\($0.displayName):\(location.remotePath)" } ?? "")]
        lines.append(L10n.format("Type: %@", item.localizedKind))
        if let size = item.size { lines.append(L10n.format("Size: %@", ByteCountFormatter.string(fromByteCount: size, countStyle: .file))) }
        if let date = item.dateModified {
            lines.append(L10n.format("Modified: %@", date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(L10n.locale))))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Helpers

    /// Runs a server change for this folder, reloads, then `then` with what `body` returned.
    private func runRemote(
        _ body: @escaping (any RemoteFileSystem, String) async throws -> String,
        then: @escaping (RemoteEndpoint, String) -> Void
    ) {
        guard let endpoint = url.remoteEndpoint else { return }
        let directory = url.remotePath
        Task {
            do {
                let result = try await RemoteConnections.shared.perform(endpoint) { try await body($0, directory) }
                // Selection first: the reload keeps whatever is selected when it starts.
                then(endpoint, result)
                reload()
            } catch is CancellationError {
            } catch {
                reload()
                Self.present(error)
            }
        }
    }

    private static func askToDeleteRemotely(_ names: [String]) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = names.count == 1
            ? L10n.format("Permanently delete “%@”?", names[0])
            : L10n.format("Permanently delete %lld items?", names.count)
        alert.informativeText = L10n.text("Items on a server can’t be moved to the Trash. This can’t be undone.")
        alert.addButton(withTitle: L10n.text("Delete"))
        alert.addButton(withTitle: L10n.text("Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }
}
