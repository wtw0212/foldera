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
| Rename | F2 |
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
| Preview pane / Details pane | ⌥⌘P / ⌥⇧⌘P |
| Undo / Redo | ⌘Z / ⇧⌘Z |

## Roadmap

- [x] **Phase 1:** tabs, breadcrumb address bar, command bar, navigation pane, details view, status bar, live refresh, inline rename, basic file operations
- [x] **Phase 2:** copy/move progress dialog with conflict handling, undo, drag and drop into folders
- [x] **Phase 3:** icon views, thumbnails, preview and details panes, Quick Look, recursive search
- [ ] **Phase 4:** bulk rename (Finder-style Replace / Add / Format with a live preview)
- [ ] **Phase 5:** optional dual pane, settings window, Fluent icons
