// Checks a release image's EdDSA signature against the public key inside the packaged app, so a release signed
// with a key the installed apps don't trust fails before it is published.
// Usage: swift verify-update-signature.swift APP FILE SIGNATURE
import CryptoKit
import Foundation

let arguments = CommandLine.arguments.dropFirst()
guard arguments.count == 3 else { fatalError("Usage: verify-update-signature.swift APP FILE SIGNATURE") }
let (app, file, signature) = (arguments[arguments.startIndex], arguments[arguments.startIndex + 1], arguments[arguments.startIndex + 2])
guard let info = NSDictionary(contentsOfFile: app + "/Contents/Info.plist"),
      let encodedKey = info["SUPublicEDKey"] as? String, let keyData = Data(base64Encoded: encodedKey),
      let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else {
    fatalError("\(app) has no valid SUPublicEDKey")
}
guard let signatureData = Data(base64Encoded: signature), let data = FileManager.default.contents(atPath: file),
      key.isValidSignature(signatureData, for: data) else {
    fatalError("\(file) isn't signed with the key in \(app)")
}
print("Verified \(file) against SUPublicEDKey \(encodedKey)")
