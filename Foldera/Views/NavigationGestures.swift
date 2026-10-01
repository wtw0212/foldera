import AppKit
import SwiftUI

/// Back / forward with Mac gestures: two-finger swipe (when "Swipe between pages" is on),
/// three-finger swipe, and the side buttons of a mouse.
struct NavigationGestures: NSViewRepresentable {
    let back: () -> Void
    let forward: () -> Void
    let canGoBack: () -> Bool
    let canGoForward: () -> Bool

    func makeNSView(context: Context) -> GestureView {
        let view = GestureView()
        view.handlers = self
        return view
    }

    func updateNSView(_ view: GestureView, context: Context) {
        view.handlers = self
    }

    static func dismantleNSView(_ view: GestureView, coordinator: ()) {
        view.removeMonitor()
    }

    final class GestureView: NSView {
        var handlers: NavigationGestures?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .swipe, .otherMouseUp]) { [weak self] event in
                guard let self, event.window === self.window else { return event }
                return self.handle(event) ? nil : event
            }
        }

        func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        /// Returns true when the event was used for navigation.
        private func handle(_ event: NSEvent) -> Bool {
            guard let handlers else { return false }
            switch event.type {
            case .otherMouseUp:
                if event.buttonNumber == 3 { handlers.back(); return true }
                if event.buttonNumber == 4 { handlers.forward(); return true }
            case .swipe:
                if event.deltaX > 0, handlers.canGoBack() { handlers.back(); return true }
                if event.deltaX < 0, handlers.canGoForward() { handlers.forward(); return true }
            case .scrollWheel:
                return trackTwoFingerSwipe(event, handlers)
            default:
                break
            }
            return false
        }

        private func trackTwoFingerSwipe(_ event: NSEvent, _ handlers: NavigationGestures) -> Bool {
            guard event.phase == .began, NSEvent.isSwipeTrackingFromScrollEventsEnabled,
                  abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) * 1.5 else { return false }
            // Fingers moving right reveal the previous page, like Safari.
            let goingBack = event.scrollingDeltaX > 0
            guard goingBack ? handlers.canGoBack() : handlers.canGoForward() else { return false }
            if canScrollHorizontally(under: event, towardLeft: goingBack) { return false }

            event.trackSwipeEvent(
                options: [.lockDirection, .clampGestureAmount],
                dampenAmountThresholdMin: goingBack ? 0 : -1,
                max: goingBack ? 1 : 0
            ) { amount, phase, _, _ in
                guard phase == .ended, abs(amount) >= 0.5 else { return }
                DispatchQueue.main.async { goingBack ? handlers.back() : handlers.forward() }
            }
            return true
        }

        /// True when the scroll view under the pointer can still scroll sideways, so the swipe should scroll it instead.
        private func canScrollHorizontally(under event: NSEvent, towardLeft: Bool) -> Bool {
            guard let content = window?.contentView,
                  let hit = content.hitTest(content.convert(event.locationInWindow, from: nil)),
                  let scroll = hit as? NSScrollView ?? hit.enclosingScrollView,
                  let document = scroll.documentView else { return false }
            let visible = scroll.contentView.bounds
            guard document.frame.width > visible.width + 1 else { return false }
            return towardLeft ? visible.minX > 0 : visible.maxX < document.frame.width - 1
        }
    }
}
