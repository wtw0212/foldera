import Foundation

/// Where an SFTP folder lives: `sftp://user@host:port/path`. One endpoint is one SSH connection.
nonisolated struct RemoteEndpoint: Hashable, Sendable, Codable {
    static let defaultPort = 22

    var host: String
    var port: Int
    var username: String

    init(host: String, port: Int = RemoteEndpoint.defaultPort, username: String) {
        self.host = host.lowercased()
        self.port = port
        self.username = username
    }

    /// Nil unless `url` is an sftp:// address with a host and user name.
    init?(url: URL) {
        guard url.scheme?.lowercased() == "sftp",
              let host = url.host(percentEncoded: false), !host.isEmpty,
              let user = url.user(percentEncoded: false), !user.isEmpty else { return nil }
        self.init(host: host, port: url.port ?? Self.defaultPort, username: user)
    }

    func url(path: String) -> URL {
        var components = URLComponents()
        components.scheme = "sftp"
        components.user = username
        components.host = host
        if port != Self.defaultPort { components.port = port }
        components.path = RemotePath.normalize(path)
        // Every component is set from validated parts, so this can't fail.
        return components.url!
    }

    var root: URL { url(path: "/") }

    /// "user@host", plus the port when it isn't 22.
    var displayName: String {
        port == Self.defaultPort ? "\(username)@\(host)" : "\(username)@\(host):\(port)"
    }

    /// The host:port key used to remember a server's host key.
    var hostKeyID: String { "\(host):\(port)" }
}

/// POSIX paths on the server. Kept separate from `NSString` path APIs, which also rewrite local paths
/// (tilde expansion, /private prefixes) and must not touch remote ones.
nonisolated enum RemotePath {
    static func normalize(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".": continue
            case "..": _ = parts.popLast()
            default: parts.append(part)
            }
        }
        return "/" + parts.joined(separator: "/")
    }

    static func join(_ directory: String, _ name: String) -> String {
        normalize(directory + "/" + name)
    }

    static func parent(of path: String) -> String {
        normalize(path + "/..")
    }

    static func name(of path: String) -> String {
        normalize(path).split(separator: "/").last.map(String.init) ?? "/"
    }

    /// True when `path` is `ancestor` or inside it.
    static func isWithin(_ path: String, _ ancestor: String) -> Bool {
        let path = normalize(path), ancestor = normalize(ancestor)
        return ancestor == "/" || path == ancestor || path.hasPrefix(ancestor + "/")
    }
}

nonisolated extension URL {
    /// An sftp:// address handled by Foldera's own SFTP client.
    var isRemote: Bool { scheme?.lowercased() == "sftp" }

    var remoteEndpoint: RemoteEndpoint? { RemoteEndpoint(url: self) }

    /// The path on the server for an sftp:// URL ("/" for the server root).
    var remotePath: String { RemotePath.normalize(path(percentEncoded: false)) }
}
