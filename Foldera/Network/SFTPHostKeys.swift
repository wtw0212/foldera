import AppKit
import Citadel
import Crypto
import NIOCore
import NIOSSH

/// Remembers each server's SSH host key (trust on first use), like `known_hosts`.
final class SFTPHostKeys {
    static let shared = SFTPHostKeys()

    enum Check: Equatable {
        case trusted
        case unknown(fingerprint: String)
        case changed(fingerprint: String)
    }

    /// Asks whether to trust a key. Replaced in tests.
    var ask: @MainActor (Check, RemoteEndpoint) -> Bool = SFTPHostKeys.askUser

    private let defaults: UserDefaults
    private static let key = "sftpHostKeys"
    /// Decisions being asked about; the SSH handshake can check the same key again while the first prompt is open.
    private var pending: [String: Task<Bool, Never>] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private var keys: [String: String] {
        get { defaults.dictionary(forKey: Self.key) as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: Self.key) }
    }

    func trustedKey(for endpoint: RemoteEndpoint) -> String? { keys[endpoint.hostKeyID] }

    func trust(_ key: String, for endpoint: RemoteEndpoint) { keys[endpoint.hostKeyID] = key }

    func forget(_ endpoint: RemoteEndpoint) { keys[endpoint.hostKeyID] = nil }

    func check(_ key: String, for endpoint: RemoteEndpoint) -> Check {
        guard let known = trustedKey(for: endpoint) else { return .unknown(fingerprint: Self.fingerprint(of: key)) }
        return known == key ? .trusted : .changed(fingerprint: Self.fingerprint(of: key))
    }

    /// True when the key is (now) trusted: known already, or accepted by the user.
    func accept(_ key: String, for endpoint: RemoteEndpoint) -> Bool {
        let check = check(key, for: endpoint)
        if check == .trusted { return true }
        guard ask(check, endpoint) else { return false }
        trust(key, for: endpoint)
        return true
    }

    /// Like `accept`, but checks of the same key that arrive while it's being asked about share one prompt.
    func decide(_ key: String, for endpoint: RemoteEndpoint) async -> Bool {
        let id = endpoint.hostKeyID + " " + key
        if let decision = pending[id] { return await decision.value }
        let decision = Task { self.accept(key, for: endpoint) }
        pending[id] = decision
        let result = await decision.value
        pending[id] = nil
        return result
    }

    /// "SHA256:…", as `ssh` prints it.
    nonisolated static func fingerprint(of openSSHKey: String) -> String {
        let parts = openSSHKey.split(separator: " ")
        guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) else { return openSSHKey }
        let digest = Data(SHA256.hash(data: blob)).base64EncodedString().replacingOccurrences(of: "=", with: "")
        return "SHA256:" + digest
    }

    func validator(for endpoint: RemoteEndpoint) -> SSHHostKeyValidator {
        .custom(HostKeyCheck { key in
            await self.decide(key, for: endpoint)
        })
    }

    private static func askUser(_ check: Check, _ endpoint: RemoteEndpoint) -> Bool {
        let alert = NSAlert()
        switch check {
        case .trusted:
            return true
        case .unknown(let fingerprint):
            alert.messageText = L10n.format("Do you trust %@?", endpoint.host)
            alert.informativeText = L10n.format("Foldera hasn’t connected to this server before. Its key fingerprint is:\n\n%@\n\nOnly continue if this matches the server you expect.", fingerprint)
            alert.addButton(withTitle: L10n.text("Trust and Connect"))
            alert.addButton(withTitle: L10n.text("Cancel"))
        case .changed(let fingerprint):
            alert.alertStyle = .critical
            alert.messageText = L10n.format("The identity of %@ has changed", endpoint.host)
            alert.informativeText = L10n.format("The server presented a different key than last time. Someone could be intercepting the connection, or the server was reinstalled. New fingerprint:\n\n%@", fingerprint)
            alert.addButton(withTitle: L10n.text("Cancel"))
            alert.addButton(withTitle: L10n.text("Trust New Key"))
            return alert.runModal() == .alertSecondButtonReturn
        }
        return alert.runModal() == .alertFirstButtonReturn
    }
}

/// Bridges NIO SSH's host key callback to an async decision.
private nonisolated struct HostKeyCheck: NIOSSHClientServerAuthenticationDelegate, Sendable {
    let decide: @Sendable (String) async -> Bool

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let key = String(openSSHPublicKey: hostKey)
        Task {
            if await decide(key) {
                validationCompletePromise.succeed(())
            } else {
                validationCompletePromise.fail(SFTPFileSystem.HostKeyRejected())
            }
        }
    }
}
