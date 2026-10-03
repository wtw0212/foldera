# Releasing Foldera

Push a version tag on the commit you want to distribute:

```bash
git tag v0.2.0
git push origin v0.2.0
```

The Release workflow tests the tagged source, builds an Apple Silicon app, and publishes `Foldera-0.2.0.dmg` and `SHA256SUMS.txt` in a GitHub release with generated release notes. Tags must use `vMAJOR.MINOR.PATCH`. The tag sets the app's version, so `project.yml` does not need a separate version edit. The Actions run number sets the build number.

Pull requests changing the release workflow, packaging script or project configuration run the same tests and packaging checks. They save build artifacts without publishing a release. **Run workflow** in GitHub Actions also performs a build without publishing.

The Release workflow uses `scripts/test.sh unit`, including the same no-skips and >80% whole-app coverage gate as CI. Packaging checks verify that Foldera is arm64-only and the bundled `7zz` runs on Apple Silicon, the app signature, language/license resources and DMG integrity. Test logs, result bundles and coverage are saved on success and failure. Ordinary source PRs are covered by the separate CI workflow documented in the README.

The workflow uses GitHub's built-in token; no personal access token is needed. Published builds are **ad-hoc signed and not notarized by Apple**. Developer ID signing and notarization require Apple Developer credentials and are not configured in this workflow. The local packaging script still supports `SIGN_IDENTITY` and `NOTARY_PROFILE` for signed and notarized builds.

For a local CI-style package:

```bash
VERSION=0.2.0 BUILD_NUMBER=42 SIGN_IDENTITY=- bash scripts/make-dmg.sh
```

Download both release files into the same directory and verify the checksum with:

```bash
shasum -a 256 -c SHA256SUMS.txt
```

The app requires an Apple Silicon Mac running macOS 26 or later. After installing, grant Full Disk Access as described in the README.
