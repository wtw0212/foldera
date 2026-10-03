import AppKit

/// Sheets for connecting to servers.
enum NetworkSheet: Identifiable, Equatable {
    /// Connect to Server, optionally pre-filled.
    case connect(String)
    /// A new or existing SFTP site; `connect` opens it after saving.
    case site(SFTPSite, connect: Bool)

    var id: String {
        switch self {
        case .connect: "connect"
        case .site(let site, _): "site:\(site.id)"
        }
    }
}

extension ExplorerWindowModel {
    /// Opens a site at its start folder (or the login folder), signing in first if needed.
    func openSite(_ site: SFTPSite, in tab: BrowserTab? = nil, connections: RemoteConnections = .shared) {
        let tab = tab ?? activeTab
        let endpoint = site.endpoint
        Task {
            do {
                let path = site.startPath.trimmingCharacters(in: .whitespaces)
                let start = path.isEmpty ? try await connections.read(endpoint) { try await $0.home() } : path
                tab.navigate(to: endpoint.url(path: start))
                tab.requestListFocus()
            } catch is CancellationError {
            } catch {
                BrowserTab.present(error)
            }
        }
    }

    func openSiteInNewTab(_ site: SFTPSite, activate: Bool = true) {
        openSite(site, in: newTab(url: BrowserTab.networkURL, activate: activate))
    }

    /// Opens a typed server address. sftp:// opens in `tab` (offering to save an unknown server as a site);
    /// smb://, afp://, nfs:// and WebDAV addresses are mounted, then opened. False when it isn't a server address.
    @discardableResult
    func openServerAddress(_ text: String, in tab: BrowserTab? = nil, mountWebAddresses: Bool = false,
                           sites: SFTPSites = .shared, mount: @escaping (URL) async throws -> URL = NetworkMounts.mount) -> Bool {
        let tab = tab ?? activeTab
        let input = text.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: input), let scheme = url.scheme?.lowercased() else { return false }
        if scheme == "sftp" || scheme == "ssh" {
            openSFTPAddress(url, in: tab, sites: sites)
            return true
        }
        guard NetworkMounts.canMount(url), mountWebAddresses || !["http", "https"].contains(scheme) else { return false }
        RecentServers.add(input) // without any password in it
        Task {
            do {
                let mounted = try await mount(url)
                VolumeMonitor.shared.refresh()
                tab.navigate(to: mounted)
                tab.requestListFocus()
            } catch is CancellationError {
            } catch {
                BrowserTab.present(error)
            }
        }
        return true
    }

    private func openSFTPAddress(_ url: URL, in tab: BrowserTab, sites: SFTPSites) {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.scheme = "sftp"
        // A password in an sftp:// address is ignored: Foldera asks for it and keeps it only in the Keychain.
        components?.password = nil
        let path = url.path(percentEncoded: false)
        if let normalized = components?.url, let endpoint = normalized.remoteEndpoint, let site = sites.site(for: endpoint) {
            RecentServers.add(normalized.absoluteString)
            if path.isEmpty || path == "/" {
                openSite(site, in: tab)
            } else {
                tab.navigate(to: endpoint.url(path: path))
            }
            return
        }
        // Unknown server: fill in a new site so it can be checked and saved first.
        var site = SFTPSite()
        site.host = url.host(percentEncoded: false) ?? ""
        site.port = url.port ?? RemoteEndpoint.defaultPort
        site.username = url.user(percentEncoded: false) ?? NSUserName()
        site.startPath = path == "/" ? "" : path
        networkSheet = .site(site, connect: true)
    }
}

/// Addresses used in Connect to Server, newest first.
enum RecentServers {
    private static let key = "recentServers"
    static let limit = 8

    /// Older builds could have saved addresses with passwords; they're cleaned when read.
    static func all(defaults: UserDefaults = .standard) -> [String] {
        let stored = defaults.stringArray(forKey: key) ?? []
        let clean = stored.map(withoutPassword)
        if clean != stored { defaults.set(clean, forKey: key) }
        return clean
    }

    static func add(_ address: String, defaults: UserDefaults = .standard) {
        let address = withoutPassword(address)
        var list = all(defaults: defaults).filter { $0.caseInsensitiveCompare(address) != .orderedSame }
        list.insert(address, at: 0)
        defaults.set(Array(list.prefix(limit)), forKey: key)
    }

    /// "smb://sam:secret@nas/share" → "smb://sam@nas/share". Passwords never go into preferences.
    static func withoutPassword(_ address: String) -> String {
        guard var components = URLComponents(string: address), components.password != nil else { return address }
        components.password = nil
        return components.string ?? address
    }

    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
    }
}
