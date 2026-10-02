import AppKit
import Observation
import SwiftUI

/// Live state of a back/forward swipe, drawn as a Chrome-style arrow bubble.
@Observable
final class SwipeFeedback {
    enum Direction { case back, forward }

    /// Gesture amount needed for the swipe to navigate.
    static let threshold: CGFloat = 0.35

    private(set) var direction: Direction = .back
    /// 0…1 how far the swipe has travelled.
    private(set) var progress: CGFloat = 0
    private(set) var isActive = false

    var isArmed: Bool { progress >= Self.threshold }

    func update(_ direction: Direction, progress: CGFloat) {
        self.direction = direction
        self.progress = min(1, max(0, progress))
        isActive = true
    }

    func end() {
        isActive = false
        progress = 0
    }

    /// Briefly shows the armed arrow, for gestures without a tracked swipe (three-finger swipe, mouse buttons).
    func flash(_ direction: Direction) {
        withAnimation(.easeOut(duration: 0.12)) { update(direction, progress: 1) }
        Task {
            try? await Task.sleep(for: .milliseconds(250))
            withAnimation(.easeOut(duration: 0.2)) { end() }
        }
    }
}

/// Back / forward with Mac gestures: two-finger swipe (when "Swipe between pages" is on),
/// three-finger swipe, and the side buttons of a mouse.
struct NavigationGestures: NSViewRepresentable {
    let feedback: SwipeFeedback
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
                if event.buttonNumber == 3, handlers.canGoBack() { handlers.feedback.flash(.back); handlers.back(); return true }
                if event.buttonNumber == 4, handlers.canGoForward() { handlers.feedback.flash(.forward); handlers.forward(); return true }
            case .swipe:
                if event.deltaX > 0, handlers.canGoBack() { handlers.feedback.flash(.back); handlers.back(); return true }
                if event.deltaX < 0, handlers.canGoForward() { handlers.feedback.flash(.forward); handlers.forward(); return true }
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

            let feedback = handlers.feedback
            let direction: SwipeFeedback.Direction = goingBack ? .back : .forward
            var navigated = false
            event.trackSwipeEvent(
                options: [.lockDirection, .clampGestureAmount],
                dampenAmountThresholdMin: goingBack ? 0 : -1,
                max: goingBack ? 1 : 0
            ) { amount, phase, isComplete, _ in
                // Called on the main thread while the fingers move, then while the swipe settles.
                MainActor.assumeIsolated {
                    if phase == .ended, !navigated, abs(amount) >= SwipeFeedback.threshold {
                        navigated = true
                        goingBack ? handlers.back() : handlers.forward()
                    }
                    if isComplete || phase == .cancelled {
                        withAnimation(.easeOut(duration: 0.18)) { feedback.end() }
                    } else if !navigated {
                        feedback.update(direction, progress: abs(amount))
                    }
                }
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

/// The arrow bubble that slides in from the edge during a swipe and fills in once letting go will navigate.
struct SwipeArrowOverlay: View {
    let feedback: SwipeFeedback

    var body: some View {
        GeometryReader { geometry in
            if feedback.isActive {
                let isBack = feedback.direction == .back
                let size: CGFloat = 64
                // Slides from fully hidden past the edge to ~24pt inside it.
                let travel = min(1, feedback.progress / SwipeFeedback.threshold)
                let inset = -size + travel * (size + 24)
                ZStack {
                    Circle()
                        .fill(feedback.isArmed ? Theme.accent.swiftUI : Color(nsColor: .init(hex: 0x2B2B2B, alpha: 0.85)))
                    Image(systemName: isBack ? "arrow.left" : "arrow.right")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(.white)
                }
                .frame(width: size, height: size)
                .scaleEffect(feedback.isArmed ? 1.08 : 0.92)
                .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
                .position(
                    x: isBack ? inset + size / 2 : geometry.size.width - inset - size / 2,
                    y: geometry.size.height / 2
                )
                .animation(.spring(response: 0.2, dampingFraction: 0.8), value: feedback.isArmed)
            }
        }
        .allowsHitTesting(false)
    }
}
