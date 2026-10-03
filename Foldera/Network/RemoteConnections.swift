import AppKit
import Citadel
import Observation

/// Open SFTP connections, one per server and user, shared by every tab and transfer.
@Observable
final class RemoteConnections {
    static let shared = RemoteConnections()

    /// Servers with a live connection, for the navigation pane and Network page.
    private(set) var connected: Set<RemoteEndpoint> = []
    @ObservationIgnored private var systems: [RemoteEndpoint: any RemoteFileSystem] = [:]
    @ObservationIgnored private var pending: [RemoteEndpoint: Task<any RemoteFileSystem, Error>] = [:]
    @ObservationIgnored private let connector: (RemoteEndpoint) async throws -> any RemoteFileSystem

    init(connector: ((RemoteEndpoint) async throws -> any RemoteFileSystem)? = nil) {
        self.connector = connector ?? { endpoint in
            // Unit tests bring their own servers; a real sign-in prompt would block the run.
            if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
                throw RemoteError.notConnected(endpoint.displayName)
            }
            return try await SFTPLogin(sites: .shared, hostKeys: .shared).connect(endpoint)
        }
    }

    /// The connection for `endpoint`, connecting (and signing in) first if needed.
    /// Concurrent callers share one attempt, so only one password prompt appears.
    func fileSystem(for endpoint: RemoteEndpoint) async throws -> any RemoteFileSystem {
        if let system = systems[endpoint] {
            if await system.isConnected { return system }
            drop(endpoint)
        }
        if let attempt = pending[endpoint] { return try await attempt.value }
        let attempt = Task { try await connector(endpoint) }
        pending[endpoint] = attempt
        defer { pending[endpoint] = nil }
        let system = try await attempt.value
        systems[endpoint] = system
        connected.insert(endpoint)
        return system
    }

    /// Runs a change on the server. It is never run twice: if the connection drops, the change may or may
    /// not have happened (a folder created but not acknowledged), so the error is reported instead, and
    /// the next operation reconnects.
    func perform<T>(_ endpoint: RemoteEndpoint, _ body: (any RemoteFileSystem) async throws -> T) async throws -> T {
        let system = try await fileSystem(for: endpoint)
        do {
            return try await body(system)
        } catch {
            if !(await system.isConnected) { drop(endpoint) }
            throw error
        }
    }

    /// Runs a read (listing, details, download), reconnecting and trying once more if the connection had
    /// silently dropped. Only for work that changes nothing on the server.
    func read<T>(_ endpoint: RemoteEndpoint, _ body: (any RemoteFileSystem) async throws -> T) async throws -> T {
        let system = try await fileSystem(for: endpoint)
        do {
            return try await body(system)
        } catch {
            guard !(await system.isConnected) else { throw error }
            drop(endpoint)
            return try await body(try await fileSystem(for: endpoint))
        }
    }

    func disconnect(_ endpoint: RemoteEndpoint) async {
        let system = systems[endpoint]
        drop(endpoint)
        await system?.close()
    }

    /// Uses an already-connected file system for `endpoint` (tests and stand-ins).
    func install(_ system: any RemoteFileSystem, for endpoint: RemoteEndpoint) {
        systems[endpoint] = system
        connected.insert(endpoint)
    }

    private func drop(_ endpoint: RemoteEndpoint) {
        systems[endpoint] = nil
        connected.remove(endpoint)
    }
}

/// Signs in to a server: uses the saved site's password or key, asks for anything missing or wrong,
/// and offers to remember a typed password in the Keychain.
struct SFTPLogin {
    struct Answer: Equatable {
        var secret: String
        var remember: Bool
    }

    enum Prompt: Equatable {
        case password(RemoteEndpoint, retry: Bool)
        case passphrase(path: String, retry: Bool)
    }

    let sites: SFTPSites
    let hostKeys: SFTPHostKeys
    /// Asks for a password or passphrase; nil when cancelled. Replaced in tests.
    var ask: @MainActor (Prompt) -> Answer? = SFTPLogin.askUser
    var connect: (RemoteEndpoint, SFTPCredentials, SSHHostKeyValidator) async throws -> any RemoteFileSystem = { endpoint, credentials, hostKey in
        try await SFTPFileSystem.connect(to: endpoint, credentials: credentials, hostKey: hostKey)
    }

    static let maxAttempts = 3

    func connect(_ endpoint: RemoteEndpoint) async throws -> any RemoteFileSystem {
        let site = sites.site(for: endpoint)
        let hostKey = hostKeys.validator(for: endpoint)
        if let site, site.authentication == .privateKey {
            return try await connectWithKey(site, endpoint: endpoint, hostKey: hostKey)
        }
        var password = site.flatMap(sites.password(for:))
        for attempt in 0..<Self.maxAttempts {
            if password == nil {
                guard let answer = ask(.password(endpoint, retry: attempt > 0)) else { throw CancellationError() }
                password = answer.secret
                if let site, answer.remember { sites.setPassword(answer.secret, for: site) }
            }
            do {
                return try await connect(endpoint, .password(password ?? ""), hostKey)
            } catch RemoteError.authenticationFailed(let server) {
                if attempt == Self.maxAttempts - 1 { throw RemoteError.authenticationFailed(server) }
                if let site { sites.setPassword(nil, for: site) }
                password = nil
            }
        }
        throw RemoteError.authenticationFailed(endpoint.displayName)
    }

    private func connectWithKey(_ site: SFTPSite, endpoint: RemoteEndpoint, hostKey: SSHHostKeyValidator) async throws -> any RemoteFileSystem {
        let path = site.expandedKeyPath
        let key: Data
        do {
            key = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            throw RemoteError.failed(L10n.format("Foldera couldn’t read the key file “%@”.", path))
        }
        var passphrase = sites.passphrase(for: site)
        for attempt in 0..<Self.maxAttempts {
            do {
                return try await connect(endpoint, .privateKey(key, path: path, passphrase: passphrase), hostKey)
            } catch is SFTPFileSystem.KeyNeedsPassphrase {
                guard let answer = ask(.passphrase(path: path, retry: attempt > 0 || passphrase != nil)) else { throw CancellationError() }
                passphrase = answer.secret
                if answer.remember { sites.setPassphrase(answer.secret, for: site) }
            } catch RemoteError.unsupportedKey(let keyPath) where passphrase != nil && attempt < Self.maxAttempts - 1 {
                // A wrong passphrase looks like an unreadable key.
                guard let answer = ask(.passphrase(path: keyPath, retry: true)) else { throw CancellationError() }
                passphrase = answer.secret
                if answer.remember { sites.setPassphrase(answer.secret, for: site) }
            }
        }
        throw RemoteError.unsupportedKey(path)
    }

    private static func askUser(_ prompt: Prompt) -> Answer? {
        let alert = NSAlert()
        switch prompt {
        case .password(let endpoint, let retry):
            alert.messageText = L10n.format("Enter the password for %@", endpoint.displayName)
            alert.informativeText = retry ? L10n.text("The password was not accepted. Try again.") : L10n.text("The server asks for a password.")
        case .passphrase(let path, let retry):
            alert.messageText = L10n.format("Enter the passphrase for “%@”", (path as NSString).lastPathComponent)
            alert.informativeText = retry ? L10n.text("The passphrase is incorrect. Try again.") : L10n.text("This private key is protected with a passphrase.")
        }
        alert.alertStyle = {
            if case .password(_, true) = prompt { return .warning }
            if case .passphrase(_, true) = prompt { return .warning }
            return .informational
        }()
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        let remember = NSButton(checkboxWithTitle: L10n.text("Remember in Keychain"), target: nil, action: nil)
        remember.state = .on
        let stack = NSStackView(views: [field, remember])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.frame = NSRect(x: 0, y: 0, width: 260, height: 52)
        alert.accessoryView = stack
        alert.addButton(withTitle: L10n.text("Connect"))
        alert.addButton(withTitle: L10n.text("Cancel"))
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return Answer(secret: field.stringValue, remember: remember.state == .on)
    }
}
