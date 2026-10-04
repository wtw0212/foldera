import CCitadelBcrypt
import Citadel
import CommonCrypto
import Crypto
import _CryptoExtras
import Foundation
import NIOCore
@preconcurrency import NIOSSH

/// Reads private key files in the formats people have and turns them into an SSH sign-in:
/// OpenSSH keys (Ed25519, RSA, ECDSA; plain or encrypted with a passphrase) and unencrypted PEM keys
/// (PKCS#1 and PKCS#8 RSA, SEC1 and PKCS#8 ECDSA, PKCS#8 Ed25519).
/// Citadel reads only OpenSSH Ed25519 and RSA keys, and signs RSA with SHA-1, which OpenSSH 8.8 and later refuse.
nonisolated enum SSHPrivateKey {
    /// The file isn't a key Foldera can use, or the passphrase is wrong.
    struct Unsupported: Error {}

    static func authenticationMethod(username: String, key: String, passphrase: Data?) throws -> SSHAuthenticationMethod {
        .custom(KeyOffer(username: username, key: try privateKey(key, passphrase: passphrase)))
    }

    static func privateKey(_ key: String, passphrase: Data?) throws -> NIOSSHPrivateKey {
        let lines = key.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let armor = lines.first, armor.hasPrefix("-----BEGIN "), armor.hasSuffix("-----") else { throw Unsupported() }
        let label = armor.dropFirst("-----BEGIN ".count).dropLast("-----".count)
        if label == "ENCRYPTED PRIVATE KEY" || lines.contains(where: { $0.hasPrefix("Proc-Type:") }) {
            // Encrypted PEM keys use legacy key derivation; `ssh-keygen -p` rewrites them as OpenSSH keys.
            throw Unsupported()
        }
        let body = lines.filter { !$0.hasPrefix("-----") }.joined()
        guard let der = Data(base64Encoded: body).map([UInt8].init) else { throw Unsupported() }
        switch label {
        case "OPENSSH PRIVATE KEY":
            return try openSSH(der, passphrase: passphrase)
        case "RSA PRIVATE KEY":
            return try pkcs1(der)
        case "EC PRIVATE KEY":
            return try sec1(der)
        case "PRIVATE KEY":
            return try pkcs8(der)
        default:
            throw Unsupported()
        }
    }

    // MARK: OpenSSH

    private static func openSSH(_ blob: [UInt8], passphrase: Data?) throws -> NIOSSHPrivateKey {
        var reader = SSHReader(blob)
        guard reader.take("openssh-key-v1\0".utf8.count) == Array("openssh-key-v1\0".utf8) else { throw Unsupported() }
        let cipher = String(decoding: try reader.string(), as: UTF8.self)
        let kdf = String(decoding: try reader.string(), as: UTF8.self)
        var kdfOptions = SSHReader(try reader.string())
        guard try reader.uint32() == 1 else { throw Unsupported() }
        _ = try reader.string() // public key, repeated in the private section
        var secret = try reader.string()
        if cipher != "none" {
            // Checked before asking, so an unreadable key isn't mistaken for a wrong passphrase.
            guard kdf == "bcrypt", let cipher = Cipher(rawValue: cipher) else { throw Unsupported() }
            guard let passphrase else { throw SFTPFileSystem.KeyNeedsPassphrase() }
            secret = try decrypt(secret, cipher: cipher, salt: try kdfOptions.string(), rounds: try kdfOptions.uint32(), passphrase: passphrase)
        }
        var key = SSHReader(secret)
        // Matching check numbers are how a wrong passphrase shows up.
        let check = try key.uint32()
        guard try key.uint32() == check else { throw Unsupported() }
        switch String(decoding: try key.string(), as: UTF8.self) {
        case "ssh-ed25519":
            _ = try key.string()
            let pair = try key.string()
            guard pair.count == 64 else { throw Unsupported() }
            return NIOSSHPrivateKey(ed25519Key: try Curve25519.Signing.PrivateKey(rawRepresentation: pair.prefix(32)))
        case "ssh-rsa":
            let n = try key.string(), e = try key.string(), d = try key.string()
            _ = try key.string() // iqmp
            let p = try key.string(), q = try key.string()
            return try rsa(n: n, e: e, d: d, p: p, q: q)
        case "ecdsa-sha2-nistp256":
            return NIOSSHPrivateKey(p256Key: try P256.Signing.PrivateKey(rawRepresentation: fixedWidth(try ecdsaScalar(&key), 32)))
        case "ecdsa-sha2-nistp384":
            return NIOSSHPrivateKey(p384Key: try P384.Signing.PrivateKey(rawRepresentation: fixedWidth(try ecdsaScalar(&key), 48)))
        case "ecdsa-sha2-nistp521":
            return NIOSSHPrivateKey(p521Key: try P521.Signing.PrivateKey(rawRepresentation: fixedWidth(try ecdsaScalar(&key), 66)))
        default:
            throw Unsupported()
        }
    }

    private static func ecdsaScalar(_ key: inout SSHReader) throws -> [UInt8] {
        _ = try key.string() // curve name
        _ = try key.string() // public point
        return try key.string()
    }

    private static let sha512ForBcrypt: Void = {
        citadel_set_crypto_hash_sha512 { out, input, length in
            _ = CC_SHA512(input, CC_LONG(length), out)
        }
    }()

    /// The ciphers ssh-keygen offers for key files, minus the AEAD ones (aes-gcm, chacha20-poly1305).
    private enum Cipher: String {
        case aes128CTR = "aes128-ctr", aes192CTR = "aes192-ctr", aes256CTR = "aes256-ctr"
        case aes128CBC = "aes128-cbc", aes192CBC = "aes192-cbc", aes256CBC = "aes256-cbc"
    }

    private static func decrypt(_ secret: [UInt8], cipher: Cipher, salt: [UInt8], rounds: UInt32, passphrase: Data) throws -> [UInt8] {
        let (keyLength, mode): (Int, CCMode) = switch cipher {
        case .aes128CTR: (16, CCMode(kCCModeCTR))
        case .aes192CTR: (24, CCMode(kCCModeCTR))
        case .aes256CTR: (32, CCMode(kCCModeCTR))
        case .aes128CBC: (16, CCMode(kCCModeCBC))
        case .aes192CBC: (24, CCMode(kCCModeCBC))
        case .aes256CBC: (32, CCMode(kCCModeCBC))
        }
        _ = sha512ForBcrypt
        let ivLength = kCCBlockSizeAES128
        var derived = [UInt8](repeating: 0, count: keyLength + ivLength)
        let status = passphrase.withUnsafeBytes { pass in
            citadel_bcrypt_pbkdf(pass.bindMemory(to: UInt8.self).baseAddress, pass.count, salt, salt.count, &derived, derived.count, rounds)
        }
        guard status == 0, secret.count % ivLength == 0 else { throw Unsupported() }
        var cryptor: CCCryptorRef?
        guard CCCryptorCreateWithMode(CCOperation(kCCDecrypt), mode, CCAlgorithm(kCCAlgorithmAES), CCPadding(ccNoPadding),
                                      Array(derived[keyLength...]), Array(derived[..<keyLength]), keyLength, nil, 0, 0,
                                      CCModeOptions(mode == CCMode(kCCModeCTR) ? kCCModeOptionCTR_BE : 0), &cryptor) == kCCSuccess,
              let cryptor else { throw Unsupported() }
        defer { CCCryptorRelease(cryptor) }
        var plain = [UInt8](repeating: 0, count: secret.count)
        var moved = 0
        guard CCCryptorUpdate(cryptor, secret, secret.count, &plain, plain.count, &moved) == kCCSuccess, moved == secret.count else { throw Unsupported() }
        return plain
    }

    // MARK: PEM

    private static let rsaEncryption: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01]
    private static let ecPublicKey: [UInt8] = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01]
    private static let ed25519: [UInt8] = [0x2B, 0x65, 0x70]

    private static func pkcs8(_ der: [UInt8]) throws -> NIOSSHPrivateKey {
        var outer = DERReader(der)
        var info = DERReader(try outer.read(0x30))
        _ = try info.read(0x02) // version
        var algorithm = DERReader(try info.read(0x30))
        let oid = try algorithm.read(0x06)
        let key = try info.read(0x04)
        switch oid {
        case rsaEncryption:
            return try pkcs1(key)
        case ecPublicKey:
            return try sec1(key)
        case ed25519:
            var seed = DERReader(key)
            return NIOSSHPrivateKey(ed25519Key: try Curve25519.Signing.PrivateKey(rawRepresentation: try seed.read(0x04)))
        default:
            throw Unsupported()
        }
    }

    /// A SEC1 EC private key, on its own or inside PKCS#8.
    private static func sec1(_ der: [UInt8]) throws -> NIOSSHPrivateKey {
        var outer = DERReader(der)
        var fields = DERReader(try outer.read(0x30))
        _ = try fields.read(0x02) // version
        let scalar = try fields.read(0x04)
        // The curve is named or spelled out (macOS's ssh-keygen does that); the scalar's fixed width tells them apart.
        _ = try fields.optional(0xA0)
        let point = try fields.optional(0xA1).map { field in
            var bits = DERReader(field)
            return Data(try bits.read(0x03).dropFirst()) // unused-bits byte
        }
        let key: NIOSSHPrivateKey, publicPoint: Data
        switch scalar.count {
        case 32:
            let ecKey = try P256.Signing.PrivateKey(rawRepresentation: scalar)
            (key, publicPoint) = (NIOSSHPrivateKey(p256Key: ecKey), ecKey.publicKey.x963Representation)
        case 48:
            let ecKey = try P384.Signing.PrivateKey(rawRepresentation: scalar)
            (key, publicPoint) = (NIOSSHPrivateKey(p384Key: ecKey), ecKey.publicKey.x963Representation)
        case 66:
            let ecKey = try P521.Signing.PrivateKey(rawRepresentation: scalar)
            (key, publicPoint) = (NIOSSHPrivateKey(p521Key: ecKey), ecKey.publicKey.x963Representation)
        default:
            throw Unsupported()
        }
        // A key on another curve of the same size, such as secp256k1, doesn't match its own public point.
        if let point, point != publicPoint { throw Unsupported() }
        return key
    }

    private static func pkcs1(_ der: [UInt8]) throws -> NIOSSHPrivateKey {
        var outer = DERReader(der)
        var fields = DERReader(try outer.read(0x30))
        _ = try fields.read(0x02) // version
        let n = try fields.read(0x02), e = try fields.read(0x02), d = try fields.read(0x02)
        let p = try fields.read(0x02), q = try fields.read(0x02)
        return try rsa(n: n, e: e, d: d, p: p, q: q)
    }

    private static func rsa(n: [UInt8], e: [UInt8], d: [UInt8], p: [UInt8], q: [UInt8]) throws -> NIOSSHPrivateKey {
        let strip = { (integer: [UInt8]) in Array(integer.drop { $0 == 0 }) }
        guard let key = try? _RSA.Signing.PrivateKey(n: strip(n), e: strip(e), d: strip(d), p: strip(p), q: strip(q)) else { throw Unsupported() }
        _ = RSASHA512.registered
        return NIOSSHPrivateKey(custom: RSASHA512.PrivateKey(key: key, n: strip(n), e: strip(e)))
    }

    private static func fixedWidth(_ integer: [UInt8], _ width: Int) throws -> [UInt8] {
        let magnitude = Array(integer.drop { $0 == 0 })
        guard magnitude.count <= width else { throw Unsupported() }
        return [UInt8](repeating: 0, count: width - magnitude.count) + magnitude
    }

    // MARK: Readers

    private struct SSHReader {
        private var bytes: ArraySlice<UInt8>
        init(_ bytes: [UInt8]) { self.bytes = bytes[...] }

        mutating func take(_ count: Int) -> [UInt8]? {
            guard count >= 0, count <= bytes.count else { return nil }
            defer { bytes = bytes.dropFirst(count) }
            return Array(bytes.prefix(count))
        }

        mutating func uint32() throws -> UInt32 {
            guard let raw = take(4) else { throw Unsupported() }
            return raw.reduce(0) { $0 << 8 | UInt32($1) }
        }

        mutating func string() throws -> [UInt8] {
            guard let value = take(Int(try uint32())) else { throw Unsupported() }
            return value
        }
    }

    /// Just enough DER to walk a private key: definite lengths and the tags the caller expects.
    private struct DERReader {
        private var bytes: ArraySlice<UInt8>
        init(_ bytes: [UInt8]) { self.bytes = bytes[...] }

        mutating func optional(_ tag: UInt8) throws -> [UInt8]? {
            bytes.first == tag ? try read(tag) : nil
        }

        mutating func read(_ tag: UInt8) throws -> [UInt8] {
            var index = bytes.startIndex
            guard bytes.count >= 2, bytes[index] == tag else { throw Unsupported() }
            index += 1
            var length = Int(bytes[index])
            index += 1
            if length & 0x80 != 0 {
                let count = length & 0x7F
                guard (1...4).contains(count), bytes.endIndex - index >= count else { throw Unsupported() }
                length = bytes[index..<index + count].reduce(0) { $0 << 8 | Int($1) }
                index += count
            }
            guard bytes.endIndex - index >= length else { throw Unsupported() }
            defer { bytes = bytes[(index + length)...] }
            return Array(bytes[index..<index + length])
        }
    }
}

/// Offers one key once; Citadel builds a fresh method for each connection.
private nonisolated final class KeyOffer: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    private let username: String
    private var key: NIOSSHPrivateKey?

    init(username: String, key: NIOSSHPrivateKey) {
        self.username = username
        self.key = key
    }

    func nextAuthenticationType(availableMethods: NIOSSHAvailableUserAuthenticationMethods,
                                nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>) {
        guard let key, availableMethods.contains(.publicKey) else {
            nextChallengePromise.fail(SSHClientError.allAuthenticationOptionsFailed)
            return
        }
        self.key = nil
        nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(username: username, serviceName: "", offer: .privateKey(.init(privateKey: key))))
    }
}

/// RSA signatures with SHA-512 (RFC 8332). The algorithm name doubles as the key blob's type, which OpenSSH
/// accepts because it maps "rsa-sha2-512" to the RSA key type.
nonisolated enum RSASHA512 {
    static let name = "rsa-sha2-512"
    /// Custom key types also become host-key algorithms, in registration order. Citadel's "ssh-rsa" goes first so a
    /// server with only an RSA host key still picks it, not "rsa-sha2-512", whose host keys NIOSSH can't read.
    static let registered: Void = {
        NIOSSHAlgorithms.register(publicKey: Insecure.RSA.PublicKey.self, signature: Insecure.RSA.Signature.self)
        NIOSSHAlgorithms.register(publicKey: PublicKey.self, signature: Signature.self)
    }()

    struct Signature: NIOSSHSignatureProtocol {
        static let signaturePrefix = RSASHA512.name
        let rawRepresentation: Data

        func write(to buffer: inout ByteBuffer) -> Int {
            buffer.writeInteger(UInt32(rawRepresentation.count)) + buffer.writeBytes(rawRepresentation)
        }

        static func read(from buffer: inout ByteBuffer) throws -> Signature {
            guard let length = buffer.readInteger(as: UInt32.self), let bytes = buffer.readData(length: Int(length)) else { throw SSHPrivateKey.Unsupported() }
            return Signature(rawRepresentation: bytes)
        }
    }

    struct PublicKey: NIOSSHPublicKeyProtocol {
        static let publicKeyPrefix = RSASHA512.name
        let n: [UInt8], e: [UInt8]

        var rawRepresentation: Data {
            var buffer = ByteBuffer()
            _ = write(to: &buffer)
            return Data(buffer.readableBytesView)
        }

        func isValidSignature<D: DataProtocol>(_ signature: NIOSSHSignatureProtocol, for data: D) -> Bool {
            guard let signature = signature as? Signature, let key = try? _RSA.Signing.PublicKey(n: n, e: e) else { return false }
            return key.isValidSignature(_RSA.Signing.RSASignature(rawRepresentation: signature.rawRepresentation),
                                        for: SHA512.hash(data: data), padding: .insecurePKCS1v1_5)
        }

        func write(to buffer: inout ByteBuffer) -> Int {
            Self.writeMPInt(e, to: &buffer) + Self.writeMPInt(n, to: &buffer)
        }

        static func read(from buffer: inout ByteBuffer) throws -> PublicKey {
            guard let eLength = buffer.readInteger(as: UInt32.self), let e = buffer.readBytes(length: Int(eLength)),
                  let nLength = buffer.readInteger(as: UInt32.self), let n = buffer.readBytes(length: Int(nLength))
            else { throw SSHPrivateKey.Unsupported() }
            return PublicKey(n: Array(n.drop { $0 == 0 }), e: Array(e.drop { $0 == 0 }))
        }

        /// An unsigned integer as an SSH mpint: a zero byte in front when the top bit is set.
        private static func writeMPInt(_ magnitude: [UInt8], to buffer: inout ByteBuffer) -> Int {
            let bytes = magnitude.first.map { $0 & 0x80 != 0 } == true ? [0] + magnitude : magnitude
            return buffer.writeInteger(UInt32(bytes.count)) + buffer.writeBytes(bytes)
        }
    }

    final class PrivateKey: NIOSSHPrivateKeyProtocol, @unchecked Sendable {
        static let keyPrefix = RSASHA512.name
        private let key: _RSA.Signing.PrivateKey
        private let _publicKey: PublicKey

        init(key: _RSA.Signing.PrivateKey, n: [UInt8], e: [UInt8]) {
            self.key = key
            self._publicKey = PublicKey(n: n, e: e)
        }

        var publicKey: NIOSSHPublicKeyProtocol { _publicKey }

        func signature<D: DataProtocol>(for data: D) throws -> NIOSSHSignatureProtocol {
            Signature(rawRepresentation: try key.signature(for: SHA512.hash(data: data), padding: .insecurePKCS1v1_5).rawRepresentation)
        }
    }
}
