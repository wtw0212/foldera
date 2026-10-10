import AppKit

/// Explorer's slow double-click: clicking the name of the only selected item again starts renaming it, once the
/// double-click interval has passed without another click (which would open the item instead).
@MainActor
final class SlowClickRename {
    /// How far the pointer may move between press and release; further is a drag.
    static let slop: CGFloat = 4

    private var pressedAt: NSPoint?
    private var pending: DispatchWorkItem?
    private let delay: () -> TimeInterval

    var isPending: Bool { pending != nil }

    init(delay: @escaping () -> TimeInterval = { NSEvent.doubleClickInterval }) {
        self.delay = delay
    }

    /// Call before the view handles a press. The click counts only if it is a single, unmodified click on the
    /// label of the item that was already the only selection, in a view that already had keyboard focus.
    func mouseDown(_ event: NSEvent, wasOnlySelection: Bool, onLabel: Bool, wasFocused: Bool) {
        cancel()
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard event.clickCount == 1, flags.isEmpty, wasOnlySelection, onLabel, wasFocused else { return }
        pressedAt = event.locationInWindow
    }

    /// Call when the press ends; renames after the double-click interval if the click wasn't a drag.
    func mouseUp(at location: NSPoint, rename: @escaping () -> Void) {
        defer { pressedAt = nil }
        guard let start = pressedAt, hypot(location.x - start.x, location.y - start.y) <= Self.slop else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.pending = nil
            rename()
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay(), execute: work)
    }

    /// Wires a view's press and release: `target` returns the item under the press (nil for empty space),
    /// `isOnlySelection` and `isOnLabel` describe it, and `rename` runs if the item is still the only selection.
    func mouseDown<Item: Equatable>(_ event: NSEvent, in view: NSView, target: Item?, isOnlySelection: (Item) -> Bool,
                                    isOnLabel: (Item) -> Bool) {
        mouseDown(event, wasOnlySelection: target.map(isOnlySelection) ?? false, onLabel: target.map(isOnLabel) ?? false,
                  wasFocused: view.window?.isKeyWindow == true && view.window?.firstResponder === view)
    }

    /// Release half of `mouseDown(_:in:target:...)`.
    func released<Item: Equatable>(_ event: NSEvent, in view: NSView, target: Item, isOnlySelection: @escaping (Item) -> Bool,
                                   rename: @escaping () -> Void) {
        mouseUp(at: event.locationInWindow) { [weak view] in
            guard let view, isOnlySelection(target), view.window?.firstResponder === view else { return }
            rename()
        }
    }

    /// Whether `point` (in `view`) falls on `label`, a subview of `cell`.
    static func hits(_ point: NSPoint, label: NSView?, in view: NSView) -> Bool {
        guard let label, let superview = label.superview else { return false }
        return superview.convert(label.frame, to: view).contains(point)
    }

    /// Any other click, key press, scroll or focus change keeps the item from going into rename.
    func cancel() {
        pending?.cancel()
        pending = nil
        pressedAt = nil
    }
}
