import SwiftUI
import UniformTypeIdentifiers

/// Windows 11 "subtle" button: transparent until hovered.
struct SubtleButtonStyle: ButtonStyle {
    var padding = EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8)

    func makeBody(configuration: Configuration) -> some View {
        SubtleButtonBody(configuration: configuration, padding: padding)
    }

    private struct SubtleButtonBody: View {
        let configuration: Configuration
        let padding: EdgeInsets
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .font(Theme.font)
                .foregroundStyle(Theme.text.swiftUI)
                .padding(padding)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(fill)
                )
                .opacity(isEnabled ? 1 : 0.4)
                .onHover { isHovered = $0 }
        }

        private var fill: Color {
            guard isEnabled else { return .clear }
            if configuration.isPressed { return Theme.subtlePressed.swiftUI }
            return isHovered ? Theme.subtleHover.swiftUI : .clear
        }
    }
}

/// Icon-only toolbar button with a tooltip.
struct IconButton: View {
    let symbol: String
    let help: String
    var tint: Color? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            AppIcon(name: symbol, size: 16)
                .foregroundStyle(tint ?? Theme.text.swiftUI)
                .frame(width: 18, height: 18)
        }
        .buttonStyle(SubtleButtonStyle())
        .hint(help)
        .accessibilityLabel(Text(help.replacingOccurrences(of: #"\s*[（(][^）)]*[）)]$"#, with: "", options: .regularExpression)))
    }
}

struct VerticalSeparator: View {
    var body: some View {
        Rectangle()
            .fill(Theme.divider.swiftUI)
            .frame(width: 1, height: 20)
            .padding(.horizontal, 4)
    }
}

/// Shows an `NSMenu` built on demand, below `anchor` (a frame in SwiftUI's global space) or at the mouse.
func popUpMenu(_ menu: NSMenu, below anchor: CGRect? = nil) {
    guard let window = NSApp.keyWindow, let view = window.contentView else { return }
    let point: NSPoint
    if let anchor {
        let y = view.isFlipped ? anchor.maxY : view.bounds.height - anchor.maxY
        point = NSPoint(x: anchor.minX, y: y + (view.isFlipped ? 2 : -2))
    } else {
        point = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
    }
    menu.popUp(positioning: nil, at: point, in: view)
}

/// A subtle button that drops down an `NSMenu` built when clicked.
struct MenuButton<Label: View>: View {
    let help: String
    let makeMenu: () -> NSMenu
    @ViewBuilder let label: () -> Label

    @State private var frame: CGRect = .zero

    var body: some View {
        Button {
            popUpMenu(makeMenu(), below: frame)
        } label: {
            label()
        }
        .buttonStyle(SubtleButtonStyle())
        .hint(help)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
    }
}

extension NSMenu {
    @discardableResult
    func add(
        _ title: String,
        symbol: String? = nil,
        checked: Bool = false,
        enabled: Bool = true,
        handler: @escaping @MainActor () -> Void
    ) -> NSMenuItem {
        let image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        let item = ClosureMenuItem(title, image: image, handler: handler)
        item.state = checked ? .on : .off
        if !enabled { item.action = nil } // menus auto-enable items, so drop the action to disable
        addItem(item)
        return item
    }

    func addSeparator() {
        addItem(.separator())
    }
}

/// `NSMenuItem` that runs a closure.
nonisolated final class ClosureMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(_ title: String, image: NSImage? = nil, keyEquivalent: String = "", handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: keyEquivalent)
        self.target = self
        self.image = image
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @MainActor @objc private func run() {
        handler()
    }
}

/// Makes a view accept dropped files into `folder`, highlighting while targeted.
struct FolderDropTarget: ViewModifier {
    let folder: URL
    @State private var isTargeted = false

    /// This Mac and Network are pages, not folders.
    static func acceptsDrops(_ folder: URL) -> Bool {
        folder != BrowserTab.thisMacURL && folder != BrowserTab.networkURL
    }

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Theme.accent.swiftUI, lineWidth: isTargeted ? 1.5 : 0)
                    .background(RoundedRectangle(cornerRadius: 4).fill(isTargeted ? Theme.hover.swiftUI : .clear))
            )
            .onDrop(of: [.fileURL, .remoteItem], isTargeted: Binding(get: { isTargeted }, set: { isTargeted = $0 && Self.acceptsDrops(folder) })) { _ in
                // The drag pasteboard can be read synchronously, and carries server items too.
                guard Self.acceptsDrops(folder) else { return false }
                return FileDrop.perform(FileDrop.fileURLs(from: NSPasteboard(name: .drag)), into: folder)
            }
    }
}

extension View {
    func folderDropTarget(_ folder: URL) -> some View {
        modifier(FolderDropTarget(folder: folder))
    }
}

/// Runs `action` on a middle-click (mouse button 3) inside the view. Watches events instead of
/// hit-testing, so SwiftUI's own clicks, hover and drags pass through untouched.
private struct MiddleClickCatcher: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> CatcherView { CatcherView() }

    func updateNSView(_ view: CatcherView, context: Context) { view.action = action }

    final class CatcherView: NSView {
        var action: (() -> Void)?
        private var monitor: Any?

        /// SwiftUI hosts don't clip `visibleRect`, so check our bounds and, for rows in a
        /// scroll view (the navigation pane), that the point is in its visible part.
        private func contains(_ windowPoint: NSPoint) -> Bool {
            guard !isHiddenOrHasHiddenAncestor, bounds.contains(convert(windowPoint, from: nil)) else { return false }
            guard let scroll = enclosingScrollView else { return true }
            return scroll.convert(scroll.bounds, to: nil).contains(windowPoint)
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseUp) { [weak self] event in
                guard let self, event.buttonNumber == 2, event.window === self.window, self.contains(event.locationInWindow) else { return event }
                self.action?()
                return nil
            }
        }
    }
}

extension View {
    func onMiddleClick(perform action: @escaping () -> Void) -> some View {
        overlay(MiddleClickCatcher(action: action))
    }
}

/// Clicking outside a focused text field (address bar, search box, rename field) ends editing,
/// like Windows. AppKit otherwise keeps the field focused until something else takes focus,
/// and empty areas (toolbar, navigation pane, status bar) never do.
enum TextFieldClickAway {
    private static var monitor: Any?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            guard let window = event.window,
                  let editor = window.firstResponder as? NSTextView, editor.isFieldEditor,
                  let field = editor.delegate as? NSView else { return event }
            // A little slack so clicks on the field's own padding keep editing.
            let hitArea = field.bounds.insetBy(dx: -10, dy: -6)
            if !hitArea.contains(field.convert(event.locationInWindow, from: nil)) {
                window.makeFirstResponder(nil)
            }
            return event
        }
    }
}

extension View {
    /// A hover tooltip. SwiftUI's `.help` silently shows nothing on some views (buttons with a background,
    /// disabled buttons, rows with hover tracking), so this registers an AppKit tooltip over the view instead.
    func hint(_ text: String) -> some View {
        overlay(ToolTipArea(text: text)).accessibilityHint(Text(text))
    }
}

/// A transparent view that only carries `toolTip`; it ignores clicks, so the view below still gets them.
private struct ToolTipArea: NSViewRepresentable {
    let text: String

    final class View: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> View {
        let view = View()
        view.toolTip = text
        return view
    }

    func updateNSView(_ view: View, context: Context) {
        if view.toolTip != text { view.toolTip = text }
    }
}
