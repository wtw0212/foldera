#!/bin/bash
# Builds a Release Foldera.app and packages it as dist/Foldera-<version>.dmg
# (the app plus an Applications shortcut to drag it onto).
#
# Optional, for sharing with other Macs (needs a paid Apple Developer account):
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"   sign the app and DMG for distribution
#   NOTARY_PROFILE=foldera   notarize with a profile saved by `xcrun notarytool store-credentials foldera`
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(sed -n 's/^ *MARKETING_VERSION: *"\(.*\)"/\1/p' project.yml | head -1)
mkdir -p dist
DMG="dist/Foldera-${VERSION}.dmg"
APP="build.noindex/release/Build/Products/Release/Foldera.app"

echo "▸ Building Foldera ${VERSION} (Release)"
xcodegen generate --quiet
SIGN_ARGS=()
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    SIGN_ARGS=(CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=${SIGN_IDENTITY}" OTHER_CODE_SIGN_FLAGS=--timestamp)
fi
xcodebuild -project Foldera.xcodeproj -scheme Foldera -configuration Release -destination 'generic/platform=macOS' \
    -derivedDataPath build.noindex/release ${SIGN_ARGS[@]+"${SIGN_ARGS[@]}"} build -quiet

echo "▸ Staging DMG contents"
rm -rf build.noindex/dmg
mkdir -p build.noindex/dmg
cp -R "$APP" build.noindex/dmg/
ln -s /Applications build.noindex/dmg/Applications

echo "▸ Creating ${DMG}"
rm -f "$DMG"
hdiutil create -volname "Foldera ${VERSION}" -srcfolder build.noindex/dmg -ov -format UDZO "$DMG" >/dev/null 2>&1

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    codesign --sign "$SIGN_IDENTITY" --timestamp "$DMG"
fi
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    echo "▸ Notarizing"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
fi

echo "✓ ${DMG} ($(du -h "$DMG" | cut -f1))"
