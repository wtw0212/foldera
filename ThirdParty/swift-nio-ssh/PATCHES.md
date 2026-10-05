# Foldera's patches to swift-nio-ssh

Base: [Joannis/swift-nio-ssh](https://github.com/Joannis/swift-nio-ssh) 0.3.5 (`791437a`), the fork Citadel 0.12.0 uses.
Only `Sources/NIOSSH` is kept; changed lines are marked `FOLDERA PATCH`.

## RFC 8332 RSA key blobs

`NIOSSHPublicKeyProtocol` gains `publicKeyFormatPrefix` (defaults to `publicKeyPrefix`). Upstream writes
`publicKeyPrefix` both as the user-auth algorithm name and as the type inside the public key blob, so an
RSA key signing with SHA-2 would send the blob as `"rsa-sha2-512", e, n`. RFC 8332 requires the algorithm
name `rsa-sha2-512` with the blob still `"ssh-rsa", e, n`. With the patch:

- the key blob is written and read using `publicKeyFormatPrefix`;
- custom types whose two prefixes differ aren't offered as server host key algorithms.

Existing custom keys (Citadel's `ssh-rsa`) behave as before.

## CVE-2026-43798 (GHSA-998x-vgvp-xwpc), backported from apple/swift-nio-ssh 0.14.1

`ECDSASignatureHelper` copied an ECDSA signature's `r` and `s` into fixed stack storage without checking they fit
the curve's point size, so a server could write past it before being authenticated. The helper now throws
`invalidSSHMessage` when either is wider. `FolderaTests/NIOSSHSignatureTests` covers P-256, P-384 and P-521.
