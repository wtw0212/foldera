import Foundation
import NIOSSH
import Testing

/// CVE-2026-43798: ECDSA signatures are read before anything is authenticated (host key exchange, certificates).
/// An `r` or `s` wider than the curve's point size must be rejected, never copied past the parser's buffer.
/// Driven through OpenSSH certificates signed by a CA on each curve, whose signature field is then replaced.
struct NIOSSHSignatureTests {
    nonisolated private static let curves = [("256", "ecdsa-sha2-nistp256", 32), ("384", "ecdsa-sha2-nistp384", 48), ("521", "ecdsa-sha2-nistp521", 66)]

    /// "type base64 comment" of a certificate for a new Ed25519 key, signed by a new ECDSA CA of `bits`.
    private func certificate(caBits bits: String) throws -> (type: String, blob: Data) {
        let directory = try TestDirectory()
        for (name, type, size) in [("ca", "ecdsa", bits), ("user", "ed25519", "256")] {
            try sshKeygen(["-q", "-t", type, "-b", size, "-N", "", "-C", "foldera-tests", "-f", directory.path(name).path])
        }
        try sshKeygen(["-q", "-s", directory.path("ca").path, "-I", "foldera-tests", "-n", "user", directory.path("user.pub").path])
        let line = try String(contentsOf: directory.path("user-cert.pub"), encoding: .utf8).split(separator: " ")
        return (String(line[0]), try #require(Data(base64Encoded: String(line[1]))))
    }

    private func sshKeygen(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
    }

    private func sshString(_ bytes: [UInt8]) -> Data {
        var length = UInt32(bytes.count).bigEndian
        return Data(bytes: &length, count: 4) + Data(bytes)
    }

    /// An Ed25519 certificate's fields before the CA's signature: strings (nil) and fixed-size integers.
    nonisolated private static let fieldsBeforeSignature: [Int?] = [nil, nil, nil, 8, 4, nil, nil, 8, 8, nil, nil, nil, nil]

    /// `blob` with its last field, the CA's signature, replaced by an ECDSA one holding `r` and `s`.
    private func replacingSignature(of blob: Data, identifier: String, r: [UInt8], s: [UInt8]) -> Data {
        var offset = blob.startIndex
        for size in Self.fieldsBeforeSignature {
            offset += size ?? 4 + blob[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) }
        }
        let lastField = offset
        let inner = sshString(r) + sshString(s)
        return blob[..<lastField] + sshString(Array(sshString(Array(identifier.utf8)) + sshString(Array(inner))))
    }

    private func parse(_ type: String, _ blob: Data) throws -> NIOSSHPublicKey {
        try NIOSSHPublicKey(openSSHPublicKey: "\(type) \(blob.base64EncodedString())")
    }

    @Test(arguments: curves)
    func oversizedSignatureComponentsAreRejected(bits: String, identifier: String, pointSize: Int) throws {
        let (type, blob) = try certificate(caBits: bits)
        _ = try parse(type, blob) // a genuine certificate still parses

        // Non-zero leading bytes, so the mpint isn't trimmed back to size.
        let fits = [UInt8](repeating: 1, count: pointSize), wide = [UInt8](repeating: 2, count: pointSize + 1)
        let huge = [UInt8](repeating: 3, count: 4096)
        for (r, s) in [(wide, fits), (fits, wide), (huge, fits), (fits, huge)] {
            let tampered = replacingSignature(of: blob, identifier: identifier, r: r, s: s)
            let error = #expect(throws: NIOSSHError.self) { try parse(type, tampered) }
            #expect(error.map(String.init(describing:))?.contains("exceeds curve point size") == true)
        }

        // A positive mpint with its top bit set carries one leading zero byte, which doesn't count. (The signature
        // itself is only checked when the certificate is validated, not when it's read.)
        let topBit = [0] + [UInt8](repeating: 0x80, count: pointSize)
        _ = try parse(type, replacingSignature(of: blob, identifier: identifier, r: topBit, s: topBit))
    }
}
