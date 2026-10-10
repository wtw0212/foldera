import AppKit
import Testing
@testable import Foldera

@MainActor
struct SlowClickRenameTests {
    private func click(_ count: Int = 1, at point: NSPoint = .zero, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: flags, timestamp: 0,
                                        windowNumber: 0, context: nil, eventNumber: 0, clickCount: count, pressure: 1))
    }

    /// Presses and releases, then reports whether rename ran after the (shortened) double-click interval.
    private func renames(_ event: NSEvent, releasedAt release: NSPoint = .zero, wasOnlySelection: Bool = true,
                         onLabel: Bool = true, wasFocused: Bool = true, interrupt: ((SlowClickRename) -> Void)? = nil) async -> Bool {
        let slowClick = SlowClickRename(delay: { 0.05 })
        var renamed = false
        slowClick.mouseDown(event, wasOnlySelection: wasOnlySelection, onLabel: onLabel, wasFocused: wasFocused)
        slowClick.mouseUp(at: release) { renamed = true }
        interrupt?(slowClick)
        try? await Task.sleep(for: .milliseconds(200))
        return renamed
    }

    @Test func secondPlainClickOnTheSelectedNameRenamesAfterTheDoubleClickInterval() async throws {
        #expect(await renames(try click()))
        #expect(await renames(try click(), releasedAt: NSPoint(x: 3, y: 2)), "a little hand movement is still a click")
    }

    @Test func otherClicksOnlySelectOrOpen() async throws {
        #expect(!(await renames(try click(2))), "double-click opens")
        #expect(!(await renames(try click(), wasOnlySelection: false)), "the first click only selects")
        #expect(!(await renames(try click(), onLabel: false)), "clicking the icon or another column selects")
        #expect(!(await renames(try click(), wasFocused: false)), "a click that focuses the list only selects")
        #expect(!(await renames(try click(flags: .command))))
        #expect(!(await renames(try click(flags: .shift))))
        #expect(!(await renames(try click(), releasedAt: NSPoint(x: 30, y: 0))), "dragging moves the item")
    }

    @Test func anotherClickOrKeyBeforeTheIntervalCancels() async throws {
        #expect(!(await renames(try click()) { $0.cancel() }))
        let slowClick = SlowClickRename(delay: { 0.05 })
        slowClick.mouseDown(try click(), wasOnlySelection: true, onLabel: true, wasFocused: true)
        slowClick.mouseUp(at: .zero) {}
        #expect(slowClick.isPending)
        slowClick.mouseDown(try click(2), wasOnlySelection: true, onLabel: true, wasFocused: true)
        #expect(!slowClick.isPending, "the second click of a double-click opens instead")
    }
}
