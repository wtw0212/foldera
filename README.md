# Foldera

A native macOS file manager that looks and works like the Windows 11 File Explorer. Built with Swift, SwiftUI and AppKit only. Keyboard shortcuts follow Mac conventions (⌘).

## Build

Requires Xcode 26+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
xcodegen generate
open Foldera.xcodeproj
```

Or from the command line:

```bash
xcodebuild -project Foldera.xcodeproj -scheme Foldera -derivedDataPath build.noindex/debug build
open build.noindex/debug/Build/Products/Debug/Foldera.app
```

`Foldera.xcodeproj` is generated from `project.yml`. Edit `project.yml`, not the project file.

## Tests and CI

```bash
bash scripts/test.sh unit  # Swift Testing: unit + real filesystem integration tests, with coverage
bash scripts/test.sh ui    # XCTest: native UI smoke tests (requires a logged-in macOS desktop)
python3 -m unittest discover -s scripts/tests -v  # CI runner, coverage gate, packaging input tests
```

Both macOS commands generate the project and use ad-hoc signing, so no Apple Developer account or personal signing config is needed. The `Testing` configuration gives the app a separate bundle identifier and preferences domain. New tests use disposable directories, named pasteboards and isolated UserDefaults suites. The existing volume tests mount disposable APFS/FAT disk images; run them on a Mac that supports `hdiutil`, not inside a restricted sandbox.

Each invocation preserves its full log, `.xcresult`, test summary and (for unit tests) `xccov` JSON under `build.noindex/test-results/<unit|ui>/run.*`. Open the result bundle in Xcode to inspect failures, coverage and UI screenshots. Extra test filters can be passed through, for example `bash scripts/test.sh unit -only-testing:FolderaTests/BrowserTabTests`; focused runs may fall below the full-suite coverage gate.

Every PR, push to `main`, and manual CI run checks workflows with actionlint, shell scripts with ShellCheck, and the Python CI tooling. Unit/integration and UI tests run on Apple Silicon/macOS 26. Results are retained for 14 days and summaries appear in the Actions run. The stable **CI passed** check fails if any required job fails, is cancelled, or is skipped; it can be selected in GitHub branch protection.

CI requires every test to pass without skips and **more than 80% line coverage across the entire Foldera app**, including Model, Services, Views, Theme and App, weighted by executable line count. No app source files are excluded. UI smoke tests cover address/history navigation, recursive search, tab shortcuts, folder creation/undo, Traditional Chinese and connecting to an SFTP server; SFTP tests run against a throwaway, key-only OpenSSH server on 127.0.0.1 that the tests start themselves; appearance fidelity, real cloud-provider accounts and macOS permission prompts still need manual checks.

### Signing

Put your Apple development team in `Config/Local.xcconfig` (not committed):

```
DEVELOPMENT_TEAM = ABCDE12345
```

A stable signature matters: macOS ties folder permissions and Full Disk Access to it. With ad-hoc signing every rebuild looks like a new app and macOS asks for access again.

For folders protected by macOS privacy controls (Mail, Safari and so on), grant Foldera **Full Disk Access** in System Settings › Privacy & Security.

## Install from a DMG

```bash
./scripts/make-dmg.sh
```

builds a Release app and writes `dist/Foldera-<version>.dmg`. Open it and drag Foldera to Applications.

Then grant Full Disk Access once: Foldera ▸ Settings ▸ Access ▸ **Open Privacy & Security Settings**, and drag Foldera (shown in Finder) into the Full Disk Access list, or click **+** and pick `/Applications/Foldera.app`. macOS never adds apps to that list by itself.

The DMG is signed with your development certificate, so it runs on your Macs. To share it with other people, set `SIGN_IDENTITY` to a Developer ID certificate and `NOTARY_PROFILE` to a notarytool profile (see the script header).

## Layout

| Path | Contents |
|---|---|
| `Foldera/App` | App entry point and menu bar commands |
| `Foldera/Model` | Window and tab state, navigation history, settings, sidebar locations |
| `Foldera/Services` | File operations, clipboard, FSEvents directory watcher |
| `Foldera/Views` | Tab strip, address bar, command bar, navigation pane |
| `Foldera/Views/FileList` | `NSTableView`-based details view, context menus |
| `Foldera/Theme` | Windows 11 colors and icons |

## Recent items

The navigation pane's **Recent** section, above Quick access, lists the last folders and files you opened (newest first; local items that were deleted or moved are skipped). It shows 5 by default; Settings ▸ General ▸ Recent items in navigation pane picks 3–20, or None to hide it. Right-click an item to remove it, or the section to clear it.

## Languages

Settings ▸ General ▸ Language switches between **Follow System**, **English** and **繁體中文** immediately and remembers the selection. Unsupported system languages fall back to English. File names, paths and shortcuts are preserved; macOS-owned dialogs and file-type descriptions use the system language.

Translations live in `Foldera/Resources/<language>.lproj` (`Localizable.strings`, `Localizable.stringsdict` for plurals, and `InfoPlist.strings` for privacy prompts). To add a language, copy those resources, translate them, add a case to `AppLanguage` and a region to `project.yml`, then regenerate the project.

## Keyboard

| Action | Shortcut |
|---|---|
| Open | Return, ⌘↓ |
| Rename (several items: bulk rename) | F2 |
| Up one level | ⌘↑ |
| Back / Forward | ⌫ or ⌘[ / ⌘] |
| Move to Trash | ⌘⌫ |
| Cut / Copy / Paste | ⌘X / ⌘C / ⌘V |
| New folder | ⇧⌘N |
| New tab / Close tab | ⌘T / ⌘W |
| Next / previous tab | ⇧⌘] / ⇧⌘[, ⌘1–9 |
| Edit address | ⌘L |
| Network / Connect to Server | ⇧⌘K / ⌘K |
| Search | ⌘F |
| Refresh | ⌘R |
| Show hidden items | ⇧⌘. |
| Properties (Get Info) | ⌘I |
| Quick Look | Space |
| Layouts (Extra large icons … Content) | ⌥⌘1–8 |
| Bigger / smaller layout (Details → List → icons) | ⌘+ / ⌘−, ⌘-scroll, pinch |
| Details pane (with preview) | ⌥⌘P |
| Undo / Redo | ⌘Z / ⇧⌘Z |
| Dual pane on/off | ⌥⌘D |
| Copy / move selection to other pane | F5 / F6 |
| Open folder in background tab / close tab | Middle-click a folder / a tab |

## Address bar commands

The address bar takes more than paths:

| Type | Does |
|---|---|
| `terminal`, `zsh`, `bash` … | Opens the terminal (Settings ▸ General) in the current folder |
| `git status`, `ls -la` | Runs the command in Terminal, in the current folder |
| `code`, `cursor`, `zed`, `subl`, `xed` | Opens the folder in that editor (`code README.md` opens a file) |
| `finder`, `open .` | Shows the folder in Finder |
| an app name (`safari`) | Launches the app |
| `https://…`, `smb://server/share` | Opens the link or connects to the share |
| `Documents`, `../dist` | Relative paths from the current folder |

## Archives

Right-click archives to **Extract here**, **Extract to “name”** or **Extract each to separate folders**; right-click anything to **Compress to ZIP file** or **Compress to 7z file**. Extraction never overwrites existing items, asks for a password when an archive is encrypted, and reads zip, 7z, rar (incl. RAR5), split archives, tar.gz/bz2/xz, iso and cab.

Foldera bundles the unmodified 7-Zip console program (`7zz`, LGPL; see `ThirdParty/7-Zip`) and runs it as a separate process. tar archives use the system `tar`; single-item ZIPs use `ditto`, like Finder.

## Cloud drives

OneDrive, Google Drive, Dropbox and Box folders in `~/Library/CloudStorage` appear in the navigation pane on their own. Settings ▸ Cloud (or right-click a cloud drive ▸ Add cloud drive) adds any other synced or network folder.

Drag a folder onto the edge of a Quick access pin, or onto the dividers around the pins, to pin it there; dropping on the middle of a pin still moves or copies into that folder.

## Network and SFTP

**Network** (⇧⌘K, or the navigation pane) lists saved SFTP sites, mounted network drives and file servers advertised on the local network. **Connect to Server** (⌘K) mounts `smb://`, `afp://`, `nfs://` and WebDAV addresses with macOS's own sign-in, like Finder, and opens `sftp://user@host[:port]/path` in Foldera. The address bar accepts the same addresses.

SFTP folders open in normal tabs, so dual pane gives a WinSCP-style local/remote layout:

- Browse, search the current folder, rename, delete (permanently, after confirming), and create folders and text files.
- Drag, or copy and paste, between local and server panes to upload and download, with progress and conflict handling. Moves within one server are renames.
- Copies omit directory symlinks; a move that would omit one stops before removing its source. If copying succeeds but source deletion fails, the complete destination is kept and the source is removed from Cut to prevent a destructive retry.
- Opening a server file downloads a temporary copy into its app; each save uploads it again.
- **Open in Terminal (SSH)** opens an `ssh` session in the current server folder.

Sites sign in with a password or an Ed25519/RSA private key in OpenSSH format. Passwords and key passphrases are kept in the macOS Keychain, never in preferences. The first connection shows the server's SHA-256 key fingerprint to confirm; a changed key is reported before anything is sent. Server changes can't be undone, and Quick Look, thumbnails and archive commands are local-only.

SFTP uses [Citadel](https://github.com/orlandos-nl/Citadel) 0.12.0 (MIT), pinned because 0.12.1 replaced its SSH dependency with an unvetted fork.

## Roadmap

- [x] **Phase 1:** tabs, breadcrumb address bar, command bar, navigation pane, details view, status bar, live refresh, inline rename, basic file operations
- [x] **Phase 2:** copy/move progress dialog with conflict handling, undo, drag and drop into folders
- [x] **Phase 3:** icon views, thumbnails, details pane with live preview, Quick Look, recursive search
- [x] **Phase 4:** bulk rename (Finder-style Replace / Add / Format with a live preview)
- [x] **Phase 5:** optional dual pane, settings window, Fluent icons

## App icon

The icon is drawn in code by `scripts/make-icon.swift`. To regenerate it:

```bash
swift scripts/make-icon.swift /tmp/icon-1024.png
```

then resize into `Foldera/Resources/Assets.xcassets/AppIcon.appiconset` (16–1024 px, e.g. with `sips -z`).

## Credits

Interface icons are [Fluent UI System Icons](https://github.com/microsoft/fluentui-system-icons) by Microsoft, used under the MIT License (see `ThirdParty/FluentUI-System-Icons-LICENSE.txt`).

Archive extraction and .7z creation use [7-Zip](https://www.7-zip.org/) by Igor Pavlov (unmodified `7zz` 26.03), licensed under the GNU LGPL 2.1 with the unRAR restriction plus BSD parts (see `ThirdParty/7-Zip/7-Zip-License.txt`, also inside the app).
