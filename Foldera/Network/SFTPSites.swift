import Foundation
import Observation
import Security

/// A saved SFTP server, like a WinSCP site.
nonisolated struct SFTPSite: Codable, Identifiable, Hashable, Sendable {
    enum Authentication: String, Codable, CaseIterable, Sendable { case password, privateKey }

    var id = UUID()
    var name = ""
    var host = ""
    var port = RemoteEndpoint.defaultPort
    var username = ""
    var authentication = Authentication.password
    /// An OpenSSH private key file; `~` is allowed.
    var keyPath = ""
    /// Where the site opens; empty means the login folder.
    var startPath = ""

    var endpoint: RemoteEndpoint { RemoteEndpoint(host: host.trimmingCharacters(in: .whitespaces), port: port, username: username) }
    var title: String { name.trimmingCharacters(in: .whitespaces).isEmpty ? endpoint.displayName : name }
    var expandedKeyPath: String { (keyPath as NSString).expandingTildeInPath }

    /// Host, user and port are required; a key site also needs its key file.
    var isComplete: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty && !username.isEmpty && (1...65535).contains(port)
            && (authentication == .password || !keyPath.isEmpty)
    }
}

/// Passwords and key passphrases, kept out of UserDefaults.
protocol SecretStore: AnyObject {
    func secret(for account: String) -> String?
    func setSecret(_ value: String?, for account: String)
}

/// The login keychain, as generic passwords under one service.
final class KeychainSecrets: SecretStore {
    static let shared = KeychainSecrets(service: "Foldera SFTP")

    private let service: String

    init(service: String) { self.service = service }

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    func secret(for account: String) -> String? {
        var query = query(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func setSecret(_ value: String?, for account: String) {
        SecItemDelete(query(account) as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var item = query(account)
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrLabel as String] = "Foldera SFTP (\(account))"
        SecItemAdd(item as CFDictionary, nil)
    }
}

/// Saved sites in UserDefaults; their secrets in a `SecretStore`.
@Observable
final class SFTPSites {
    static let shared = SFTPSites()

    private(set) var sites: [SFTPSite]
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored let secrets: SecretStore
    private static let key = "sftpSites"

    init(defaults: UserDefaults = .standard, secrets: SecretStore = KeychainSecrets.shared) {
        self.defaults = defaults
        self.secrets = secrets
        sites = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([SFTPSite].self, from: $0) } ?? []
    }

    /// Adds or updates a site. A nil password leaves the saved one alone; an empty one forgets it.
    func save(_ site: SFTPSite, password: String? = nil) {
        if let index = sites.firstIndex(where: { $0.id == site.id }) {
            sites[index] = site
        } else {
            sites.append(site)
        }
        if let password { setPassword(password, for: site) }
        persist()
    }

    func remove(_ site: SFTPSite) {
        sites.removeAll { $0.id == site.id }
        secrets.setSecret(nil, for: "password:\(site.id)")
        secrets.setSecret(nil, for: "passphrase:\(site.id)")
        persist()
    }

    func site(for endpoint: RemoteEndpoint) -> SFTPSite? {
        sites.first { $0.endpoint == endpoint }
    }

    func password(for site: SFTPSite) -> String? { secrets.secret(for: "password:\(site.id)") }
    func setPassword(_ password: String?, for site: SFTPSite) { secrets.setSecret(password, for: "password:\(site.id)") }
    func passphrase(for site: SFTPSite) -> String? { secrets.secret(for: "passphrase:\(site.id)") }
    func setPassphrase(_ passphrase: String?, for site: SFTPSite) { secrets.setSecret(passphrase, for: "passphrase:\(site.id)") }

    private func persist() {
        defaults.set(try? JSONEncoder().encode(sites), forKey: Self.key)
    }
}
