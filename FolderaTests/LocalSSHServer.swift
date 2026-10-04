import Foundation
@testable import Foldera

/// A throwaway OpenSSH server on 127.0.0.1, run as the current user with key-only login.
/// macOS ships /usr/sbin/sshd and sftp-server, so SFTP tests need no network or root.
nonisolated final class LocalSSHServer: Sendable {
    let directory: TestDirectory
    let port: Int
    let clientKey: URL
    let hostPublicKey: String
    private let process: Process

    var endpoint: RemoteEndpoint { RemoteEndpoint(host: "127.0.0.1", port: port, username: NSUserName()) }

    /// `hostKeyType` is an ssh-keygen key type; `extraConfig` adds sshd_config lines (e.g. PubkeyAcceptedAlgorithms).
    init(hostKeyType: String = "ed25519", extraConfig: String = "") throws {
        directory = try TestDirectory()
        let root = directory.url
        for (name, type) in [("host", hostKeyType), ("client", "ed25519")] {
            try Self.run("/usr/bin/ssh-keygen", ["-q", "-t", type, "-N", "", "-C", "foldera-tests", "-f", root.appendingPathComponent(name).path])
        }
        clientKey = root.appendingPathComponent("client")
        hostPublicKey = try String(contentsOf: root.appendingPathComponent("host.pub"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try FileManager.default.copyItem(at: root.appendingPathComponent("client.pub"), to: root.appendingPathComponent("authorized_keys"))
        port = try Self.freePort()
        let config = """
        Port \(port)
        ListenAddress 127.0.0.1
        HostKey \(root.path)/host
        PidFile \(root.path)/sshd.pid
        AuthorizedKeysFile \(root.path)/authorized_keys
        PasswordAuthentication no
        KbdInteractiveAuthentication no
        UsePAM no
        StrictModes no
        Subsystem sftp /usr/libexec/sftp-server
        \(extraConfig)
        """
        try config.write(to: root.appendingPathComponent("sshd_config"), atomically: true, encoding: .utf8)
        process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/sshd")
        process.arguments = ["-D", "-e", "-f", root.appendingPathComponent("sshd_config").path]
        process.standardError = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        try Self.waitForPort(port)
    }

    deinit {
        process.terminate()
        process.waitUntilExit()
    }

    var credentials: SFTPCredentials {
        get throws { .privateKey(try Data(contentsOf: clientKey), path: clientKey.path, passphrase: nil) }
    }

    /// Generates another client key with `ssh-keygen` options (type, format, passphrase) and lets it log in.
    func authorizeKey(_ name: String, _ options: [String]) throws -> URL {
        let key = directory.path(name)
        try Self.run("/usr/bin/ssh-keygen", ["-q", "-C", "foldera-tests", "-f", key.path] + options)
        let authorized = try FileHandle(forWritingTo: directory.path("authorized_keys"))
        defer { try? authorized.close() }
        try authorized.seekToEnd()
        try authorized.write(contentsOf: Data(contentsOf: key.appendingPathExtension("pub")))
        return key
    }

    func connect() async throws -> SFTPFileSystem {
        try await SFTPFileSystem.connect(to: endpoint, credentials: credentials, hostKey: .acceptAnything())
    }

    private static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.executableLoad) }
    }

    private static func freePort() throws -> Int {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        defer { close(socket) }
        var address = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET),
                                  sin_port: 0, sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")), sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socket, $0, length) == 0 && getsockname(socket, $0, &length) == 0
            }
        }
        guard bound else { throw POSIXError(.EADDRINUSE) }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    private static func waitForPort(_ port: Int) throws {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
            var address = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET),
                                      sin_port: in_port_t(UInt16(port).bigEndian), sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")),
                                      sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
                }
            }
            close(socket)
            if connected { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw POSIXError(.ETIMEDOUT)
    }
}
