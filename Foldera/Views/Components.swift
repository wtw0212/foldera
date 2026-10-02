import SwiftUI

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
        .help(help)
        .accessibilityLabel(Text(help.replacingOccurrences(of: #" \(.*\)$"#, with: "", options: .regularExpression)))
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
        .help(help)
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

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Theme.accent.swiftUI, lineWidth: isTargeted ? 1.5 : 0)
                    .background(RoundedRectangle(cornerRadius: 4).fill(isTargeted ? Theme.hover.swiftUI : .clear))
            )
            .dropDestination(for: URL.self) { urls, _ in
                FileDrop.perform(urls.filter(\.isFileURL), into: folder)
            } isTargeted: { isTargeted = $0 }
    }
}

extension View {
    func folderDropTarget(_ folder: URL) -> some View {
        modifier(FolderDropTarget(folder: folder))
    }
}
