import Foundation
import Network
import Observation

/// File servers advertised on the local network over Bonjour (SMB, AFP, SFTP), like Finder's Network.
@Observable
final class NetworkBrowser {
    /// Doesn't browse inside tests, which would ask for local network access.
    static let shared = NetworkBrowser(canBrowse: ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil)

    enum Service: String, CaseIterable, Comparable, Sendable {
        case smb = "_smb._tcp"
        case afp = "_afpovertcp._tcp"
        case sftp = "_sftp-ssh._tcp"
        case ssh = "_ssh._tcp"

        var label: String {
            switch self {
            case .smb: "SMB"
            case .afp: "AFP"
            case .sftp, .ssh: "SFTP"
            }
        }

        static func < (a: Service, b: Service) -> Bool {
            allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
        }
    }

    /// One computer, with every file service it offers.
    struct Server: Identifiable, Hashable {
        let name: String
        var services: Set<Service>
        var id: String { name }

        var offersFileSharing: Bool { services.contains(.smb) || services.contains(.afp) }
        var offersSFTP: Bool { services.contains(.sftp) || services.contains(.ssh) }
        var protocols: String { Set(services.map(\.label)).sorted().joined(separator: ", ") }

        /// Finder-style Bonjour address, which macOS resolves when mounting.
        var sharingURL: URL? {
            let service: Service = services.contains(.smb) ? .smb : .afp
            guard offersFileSharing, let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) else { return nil }
            return URL(string: "\(service == .smb ? "smb" : "afp")://\(encoded).\(service.rawValue).local")
        }
    }

    private(set) var servers: [Server] = []
    private(set) var isBrowsing = false
    @ObservationIgnored private var browsers: [NWBrowser] = []
    @ObservationIgnored private var found: [Service: Set<String>] = [:]
    /// False in tests, which must not trigger the local network permission prompt.
    @ObservationIgnored private let canBrowse: Bool

    init(canBrowse: Bool = true) {
        self.canBrowse = canBrowse
    }

    /// Starts browsing. macOS asks for local network access the first time.
    func start() {
        guard canBrowse, browsers.isEmpty else { return }
        isBrowsing = true
        for service in Service.allCases {
            let browser = NWBrowser(for: .bonjour(type: service.rawValue, domain: "local."), using: .tcp)
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                let names = Set(results.compactMap { result -> String? in
                    if case .service(let name, _, _, _) = result.endpoint { return name }
                    return nil
                })
                MainActor.assumeIsolated { self?.update(service, names) }
            }
            browser.start(queue: .main)
            browsers.append(browser)
        }
    }

    func stop() {
        browsers.forEach { $0.cancel() }
        browsers = []
        isBrowsing = false
    }

    func update(_ service: Service, _ names: Set<String>) {
        found[service] = names
        var byName: [String: Set<Service>] = [:]
        for (service, names) in found {
            for name in names { byName[name, default: []].insert(service) }
        }
        servers = byName.map { Server(name: $0.key, services: $0.value) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The address of a computer's SSH service, for a new SFTP site.
    static func resolveSFTP(_ server: Server, timeout: Duration = .seconds(5)) async -> (host: String, port: Int)? {
        let service: Service = server.services.contains(.sftp) ? .sftp : .ssh
        let parameters = NWParameters.tcp
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4 // A link-local IPv6 address needs an interface suffix that SSH hosts can't take.
        }
        let connection = NWConnection(to: .service(name: server.name, type: service.rawValue, domain: "local.", interface: nil), using: parameters)
        return await withCheckedContinuation { continuation in
            let once = Once()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    var resolved: (String, Int)?
                    if case .hostPort(let host, let port) = connection.currentPath?.remoteEndpoint {
                        resolved = ("\(host)".split(separator: "%").first.map(String.init).map { ($0, Int(port.rawValue)) }) ?? nil
                    }
                    if once.claim() { continuation.resume(returning: resolved.map { (host: $0.0, port: $0.1) }) }
                    connection.cancel()
                case .failed, .cancelled:
                    if once.claim() { continuation.resume(returning: nil) }
                default: break
                }
            }
            connection.start(queue: .main)
            Task {
                try? await Task.sleep(for: timeout)
                if once.claim() { continuation.resume(returning: nil) }
                connection.cancel()
            }
        }
    }
}

/// Lets exactly one of several callbacks resume a continuation.
private nonisolated final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.withLock {
            defer { claimed = true }
            return !claimed
        }
    }
}
