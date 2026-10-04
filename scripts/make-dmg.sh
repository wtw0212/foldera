#!/bin/bash
# Builds a Release Foldera.app and packages it as dist/Foldera-<version>.dmg
# (the app plus an Applications shortcut to drag it onto).
#
# Optional, for sharing with other Macs (needs a paid Apple Developer account):
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"   sign the app and DMG for distribution
#   NOTARY_PROFILE=foldera   notarize with a profile saved by `xcrun notarytool store-credentials foldera`
#   SIGN_IDENTITY=-   build with ad-hoc signing, without an Apple developer certificate
#   VERSION=0.2.0 BUILD_NUMBER=42   override the version and build number for a release
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=${VERSION:-$(sed -n 's/^ *MARKETING_VERSION: *"\(.*\)"/\1/p' project.yml | head -1)}
if [[ ! "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
    echo "Version must be MAJOR.MINOR.PATCH, for example 0.2.0" >&2
    exit 1
fi
BUILD_NUMBER=${BUILD_NUMBER:-1}
if [[ ! "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
    echo "Build number must be a positive integer" >&2
    exit 1
fi
mkdir -p dist
DMG="dist/Foldera-${VERSION}.dmg"
SYMBOLS="dist/Foldera-${VERSION}.dSYM.zip"
APP="build.noindex/release/Build/Products/Release/Foldera.app"

echo "▸ Building Foldera ${VERSION} (Release)"
FOLDERA_INSTALLER_ID=$(uuidgen)
xcodegen generate --quiet
SIGN_ARGS=()
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    SIGN_ARGS=(CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=${SIGN_IDENTITY}")
    if [[ "$SIGN_IDENTITY" != "-" ]]; then
        SIGN_ARGS+=(OTHER_CODE_SIGN_FLAGS=--timestamp)
    fi
fi
# Re-link from cached object files: an incremental dSYM must not be regenerated
# from the previous build's already-stripped executable.
rm -f "$APP/Contents/MacOS/Foldera"
xcodebuild -project Foldera.xcodeproj -scheme Foldera -configuration Release -destination 'generic/platform=macOS' \
    -derivedDataPath build.noindex/release "MARKETING_VERSION=$VERSION" "CURRENT_PROJECT_VERSION=$BUILD_NUMBER" \
    "FOLDERA_INSTALLER_ID=$FOLDERA_INSTALLER_ID" \
    ENABLE_CODE_COVERAGE=NO DEPLOYMENT_POSTPROCESSING=YES DEAD_CODE_STRIPPING=YES COMPILER_INDEX_STORE_ENABLE=NO \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=NO ${SIGN_ARGS[@]+"${SIGN_ARGS[@]}"} build -quiet

echo "▸ Saving external debug symbols"
rm -f "$SYMBOLS"
ditto -c -k --keepParent "$APP.dSYM" "$SYMBOLS"

echo "▸ Staging DMG contents"
rm -rf build.noindex/dmg
mkdir -p build.noindex/dmg
cp -R "$APP" build.noindex/dmg/
ln -s /Applications build.noindex/dmg/Applications
python3 scripts/installer-receipt.py

echo "▸ Creating ${DMG}"
rm -f "$DMG"
hdiutil create -volname "Foldera ${VERSION}" -srcfolder build.noindex/dmg -ov -format ULMO "$DMG" >/dev/null 2>&1

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    if [[ "$SIGN_IDENTITY" == "-" ]]; then
        codesign --sign - "$DMG"
    else
        codesign --sign "$SIGN_IDENTITY" --timestamp "$DMG"
    fi
fi
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    echo "▸ Notarizing"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
fi

echo "✓ ${DMG} ($(du -h "$DMG" | cut -f1))"
