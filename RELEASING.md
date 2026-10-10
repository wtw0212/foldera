# Releasing Foldera

Push a version tag on the commit you want to distribute:

```bash
git tag v0.2.0
git push origin v0.2.0
```

The Release workflow tests the tagged source, builds an Apple Silicon app, and publishes `Foldera-0.2.0.dmg` and `SHA256SUMS.txt` in a GitHub release with generated release notes. Tags must use `vMAJOR.MINOR.PATCH`. The tag sets the app's version, so `project.yml` does not need a separate version edit. The Actions run number sets the build number.

Pull requests changing the release workflow, packaging script or project configuration run the same tests and packaging checks. They save build artifacts without publishing a release. **Run workflow** in GitHub Actions also performs a build without publishing.

The Release workflow uses `scripts/test.sh unit`, including the same no-skips and >80% whole-app coverage gate as CI. Packaging checks verify that Foldera is arm64-only and the bundled `7zz` runs on Apple Silicon, the app signature, language/license resources and DMG integrity. Test logs, result bundles and coverage are saved on success and failure. Ordinary source PRs are covered by the separate CI workflow documented in the README.

Each release also carries `appcast.xml`, the feed installed copies read from `releases/latest/download/appcast.xml`. The workflow signs the DMG and the feed with the `SPARKLE_PRIVATE_KEY` repository secret, checks the DMG signature against the `SUPublicEDKey` built into the app, and fails without the secret. An installed copy rejects any update or feed not signed with that key.

### Update signing key (one-time setup)

The key pair was created with Sparkle's `generate_keys --account foldera`; the private key is in the release manager's login keychain and the public key is `SPARKLE_PUBLIC_KEY` in `project.yml`. Add the private key to the repository once:

```bash
build.noindex/release/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys --account foldera -x sparkle-private-key
gh secret set SPARKLE_PRIVATE_KEY < sparkle-private-key
rm sparkle-private-key
```

(`generate_keys` appears there after one `scripts/make-dmg.sh` run.) Back up the private key somewhere safe: if it is lost, installed copies can't accept any further update and users must reinstall from a DMG built with a new key. Never change `SPARKLE_PUBLIC_KEY` without that in mind.

The workflow uses GitHub's built-in token; no personal access token is needed. Published builds are **ad-hoc signed and not notarized by Apple**. Ad-hoc builds get `Foldera-AdHoc.entitlements`, which turns off library validation so the embedded Sparkle.framework can load without a Team ID; Developer ID builds keep it on. Developer ID signing and notarization require Apple Developer credentials and are not configured in this workflow. The local packaging script still supports `SIGN_IDENTITY` and `NOTARY_PROFILE` for signed and notarized builds.

For a local CI-style package:

```bash
VERSION=0.2.0 BUILD_NUMBER=42 SIGN_IDENTITY=- bash scripts/make-dmg.sh
```

Download both release files into the same directory and verify the checksum with:

```bash
shasum -a 256 -c SHA256SUMS.txt
```

The app requires an Apple Silicon Mac running macOS 26 or later. After installing, grant Full Disk Access as described in the README.
