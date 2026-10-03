import AppKit
import Testing
@testable import Foldera

@MainActor
private final class CommandRecorder: FileViewCommands {
    var calls: [String] = []
    var hasSelection = false
    var canPaste = false
    func openSelection() { calls.append("open") }
    func beginRename() { calls.append("rename") }
    func goUp() { calls.append("up") }
    func goBack() { calls.append("back") }
    func trashSelection() { calls.append("delete") }
    func cutSelection() { calls.append("cut") }
    func copySelection() { calls.append("copy") }
    func paste() { calls.append("paste") }
    func toggleQuickLook() { calls.append("preview") }
    func zoom(in zoomIn: Bool) { calls.append(zoomIn ? "zoom-in" : "zoom-out") }
    func openInBackgroundTab(index: Int) { calls.append("background:\(index)") }
    func contextMenu(forRow row: Int) -> NSMenu? {
        calls.append("menu:\(row)")
        return NSMenu()
    }
}

@MainActor
struct FileViewInteractionTests {
    private func key(_ code: UInt16, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
    }

    @Test func shortcutRoutingHonoursModifiersAndReturnPreference() throws {
        let recorder = CommandRecorder()
        let preferences = try TestPreferences(), settings = AppSettings(defaults: preferences.defaults)
        settings.returnKeyRenames = false
        let cases: [(UInt16, NSEvent.ModifierFlags, String)] = [
            (36, [], "open"), (76, [], "open"), (125, .command, "open"),
            (126, [.command, .function, .numericPad], "up"), (120, [], "rename"),
            (51, [], "back"), (51, .command, "delete"), (117, [], "delete"), (49, [], "preview"),
        ]
        for (code, flags, expected) in cases {
            #expect(try FileKeys.handle(key(code, flags: flags), recorder, settings: settings))
            #expect(recorder.calls.last == expected)
        }
        settings.returnKeyRenames = true
        #expect(try FileKeys.handle(key(36), recorder, settings: settings))
        #expect(recorder.calls.last == "rename")
        let count = recorder.calls.count
        #expect(try !FileKeys.handle(key(36, flags: .shift), recorder, settings: settings))
        #expect(try !FileKeys.handle(key(0), recorder, settings: settings) && recorder.calls.count == count)
    }

    @Test func commandPlusAndMinusZoomTheLayout() throws {
        let recorder = CommandRecorder()
        for (code, flags) in [(UInt16(24), NSEvent.ModifierFlags.command), (24, [.command, .shift]), (69, [.command, .numericPad])] {
            #expect(try FileKeys.handle(key(code, flags: flags), recorder))
            #expect(recorder.calls.last == "zoom-in")
        }
        for code: UInt16 in [27, 78] {
            #expect(try FileKeys.handle(key(code, flags: .command), recorder))
            #expect(recorder.calls.last == "zoom-out")
        }
        #expect(try !FileKeys.handle(key(24), recorder), "= without ⌘ is typing")
    }

    @Test func editMenuValidationUsesSelectionAndFileClipboardState() {
        let recorder = CommandRecorder()
        for selector in [#selector(NSText.copy(_:)), #selector(NSText.cut(_:)), #selector(NSText.delete(_:)), #selector(NSText.paste(_:))] {
            let item = NSMenuItem(title: "", action: selector, keyEquivalent: "")
            #expect(FileKeys.validate(item, recorder) == false)
            recorder.hasSelection = true
            recorder.canPaste = true
            #expect(FileKeys.validate(item, recorder) == true)
            #expect(FileKeys.validate(item, nil) == false)
            recorder.hasSelection = false
            recorder.canPaste = false
        }
        #expect(FileKeys.validate(NSMenuItem(title: "", action: nil, keyEquivalent: ""), recorder) == nil)
    }

    @Test func bothNativeViewsForwardEditActionsAndKeyboardCommands() throws {
        let recorder = CommandRecorder()
        let table = FileTableView(), grid = FileCollectionView()
        table.commands = recorder
        grid.commands = recorder
        table.copy(nil); table.cut(nil); table.paste(nil); table.delete(nil)
        grid.copy(nil); grid.cut(nil); grid.paste(nil); grid.delete(nil)
        #expect(recorder.calls == ["copy", "cut", "paste", "delete", "copy", "cut", "paste", "delete"])
        table.keyDown(with: try key(120))
        grid.keyDown(with: try key(120))
        #expect(recorder.calls.suffix(2) == ["rename", "rename"])
        let copy = NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "")
        #expect(!table.validateUserInterfaceItem(copy) && !grid.validateMenuItem(copy))
        recorder.hasSelection = true
        #expect(table.validateUserInterfaceItem(copy) && grid.validateMenuItem(copy))
        table.updateTrackingAreas(); table.updateTrackingAreas()
        grid.updateTrackingAreas(); grid.updateTrackingAreas()
        #expect(table.columnsMaxX == table.bounds.width)
        #expect(table.acceptsPreviewPanelControl(nil) && grid.acceptsPreviewPanelControl(nil))
    }

    @Test func inlineRenameKeepsHiddenExtensionsAndCancelPreservesTheFile() async throws {
        let directory = try TestDirectory(), preferences = try TestPreferences()
        let url = try directory.file("before.txt", contents: "same bytes")
        let tab = BrowserTab(url: directory.url, settings: AppSettings(defaults: preferences.defaults))
        try await eventually { !tab.isLoading }
        let field = NSTextField(), renamer = InlineRenamer()
        var editing = false, finishes = 0
        renamer.onFinish = { finishes += 1 }
        renamer.begin(field: field, item: FileItem(url: url), showExtensions: false, tab: tab) { editing = $0 }
        #expect(renamer.isEditing && editing && field.stringValue == "before")
        field.stringValue = "after"
        renamer.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification))
        #expect(!renamer.isEditing && !editing && finishes == 1)
        #expect(try String(contentsOf: directory.path("after.txt"), encoding: .utf8) == "same bytes")
        renamer.begin(field: field, item: FileItem(url: directory.path("after.txt")), showExtensions: true, tab: tab) { editing = $0 }
        #expect(field.stringValue == "after.txt")
        field.stringValue = "cancelled.txt"
        #expect(!renamer.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.moveDown(_:))))
        #expect(renamer.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        #expect(!editing && !renamer.isEditing && finishes == 2 && FileOperations.exists(directory.path("after.txt")))
        #expect(!FileOperations.exists(directory.path("cancelled.txt")))
        renamer.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification))
        #expect(finishes == 2)
    }

    @Test func selectionBoxIsTransparentToMouseEventsAndUsesTheAccentColor() {
        let view = SelectionBoxView(frame: NSRect(x: 0, y: 0, width: 50, height: 20))
        view.updateLayer()
        #expect(view.wantsUpdateLayer && view.layer?.borderWidth == 1)
        #expect(view.layer?.borderColor == Theme.accent.cgColor)
        #expect(view.hitTest(.zero) == nil)
    }
}
