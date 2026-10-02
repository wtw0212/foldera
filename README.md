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
xcodebuild -project Foldera.xcodeproj -scheme Foldera -derivedDataPath build/DerivedData build
open build/DerivedData/Build/Products/Debug/Foldera.app
```

`Foldera.xcodeproj` is generated from `project.yml`. Edit `project.yml`, not the project file.

### Signing

Put your Apple development team in `Config/Local.xcconfig` (not committed):

```
DEVELOPMENT_TEAM = ABCDE12345
```

A stable signature matters: macOS ties folder permissions and Full Disk Access to it. With ad-hoc signing every rebuild looks like a new app and macOS asks for access again.

For folders protected by macOS privacy controls (Mail, Safari and so on), grant Foldera **Full Disk Access** in System Settings › Privacy & Security.

## Layout

| Path | Contents |
|---|---|
| `Foldera/App` | App entry point and menu bar commands |
| `Foldera/Model` | Window and tab state, navigation history, settings, sidebar locations |
| `Foldera/Services` | File operations, clipboard, FSEvents directory watcher |
| `Foldera/Views` | Tab strip, address bar, command bar, navigation pane |
| `Foldera/Views/FileList` | `NSTableView`-based details view, context menus |
| `Foldera/Theme` | Windows 11 colors and icons |

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
| Search | ⌘F |
| Refresh | ⌘R |
| Show hidden items | ⇧⌘. |
| Properties (Get Info) | ⌘I |
| Quick Look | Space |
| Layouts (Extra large icons … Content) | ⌥⌘1–8 |
| Details pane (with preview) | ⌥⌘P |
| Undo / Redo | ⌘Z / ⇧⌘Z |
| Dual pane on/off | ⌥⌘D |
| Copy / move selection to other pane | F5 / F6 |

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
