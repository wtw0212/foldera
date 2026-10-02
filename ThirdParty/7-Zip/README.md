# 7-Zip

`7zz` is the unmodified 7-Zip console build for macOS (universal: arm64 + x86_64), used by Foldera
to extract archives and create .7z files. It runs as a separate program bundled in
`Foldera.app/Contents/MacOS`.

- Version: 26.03 (2026-09-03)
- Source and downloads: https://www.7-zip.org/ (macOS build: https://github.com/ip7z/7zip/releases/tag/26.03)
- Download: `7z2603-mac.tar.xz`, SHA-256 `5ca87677072c59f5602e5c49baa27d4694bacd2259b4e507f0094249d4281480`
- License: GNU LGPL 2.1 with the unRAR restriction for the RAR decoder, plus BSD 2/3-clause parts.
  See `7-Zip-License.txt`, which is also copied into the app.

To update, run `scripts/update-7zip.sh <version> <sha256>` (for example `26.03 5ca8…`).
