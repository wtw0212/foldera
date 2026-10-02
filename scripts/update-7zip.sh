#!/bin/bash
# Replaces ThirdParty/7-Zip/7zz with an official 7-Zip macOS console build.
# Usage: scripts/update-7zip.sh 26.03 <sha256 of 7zXXXX-mac.tar.xz>
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=${1:?version, e.g. 26.03}
SHA256=${2:?sha256 of the download}
NAME="7z${VERSION//./}-mac.tar.xz"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
curl -fsSL -o "$WORK/$NAME" "https://github.com/ip7z/7zip/releases/download/$VERSION/$NAME"
echo "$SHA256  $WORK/$NAME" | shasum -a 256 -c -
tar -xf "$WORK/$NAME" -C "$WORK"
install -m 755 "$WORK/7zz" ThirdParty/7-Zip/7zz
install -m 644 "$WORK/License.txt" ThirdParty/7-Zip/7-Zip-License.txt
xattr -c ThirdParty/7-Zip/7zz
echo "Updated 7zz to $VERSION. Update the version and checksum in ThirdParty/7-Zip/README.md."
