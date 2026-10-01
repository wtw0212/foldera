import SwiftUI

/// Explorer tabs drawn in the title bar area.
struct TabStrip: View {
    @Bindable var model: ExplorerWindowModel

    /// Leaves room for the traffic-light window buttons.
    private let leadingInset: CGFloat = 78

    var body: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: leadingInset)
            ForEach(model.tabs) { tab in
                let isActive = tab.id == model.activeTabID
                TabItem(
                    tab: tab,
                    isActive: isActive,
                    select: { model.activeTabID = tab.id },
                    close: {
                        if !model.closeTab(tab.id) { NSApp.keyWindow?.performClose(nil) }
                    }
                )
                .draggable(tab.id.uuidString)
                .dropDestination(for: String.self) { ids, _ in
                    guard let id = ids.first.flatMap(UUID.init(uuidString:)) else { return false }
                    model.moveTab(id, before: tab.id)
                    return true
                }
            }
            Button {
                model.newTab()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(SubtleButtonStyle())
            .padding(.leading, 4)
            .padding(.bottom, 2)
            .help("Open new tab (⌘T)")

            WindowDragArea()
        }
        .frame(height: 40, alignment: .bottom)
    }
}

private struct TabItem: View {
    let tab: BrowserTab
    let isActive: Bool
    let select: () -> Void
    let close: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: FileIcons.folder)
                .resizable()
                .frame(width: 16, height: 16)
            Text(tab.title)
                .font(Theme.font)
                .foregroundStyle(Theme.text.swiftUI)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(SubtleButtonStyle(padding: EdgeInsets(top: 3, leading: 3, bottom: 3, trailing: 3)))
            .opacity(isActive || isHovered ? 1 : 0)
            .help("Close tab (⌘W)")
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(minWidth: 120, idealWidth: 220, maxWidth: 240, minHeight: 32, maxHeight: 32)
        .background(background)
        .overlay(alignment: .trailing) {
            if !isActive {
                Rectangle().fill(Theme.divider.swiftUI).frame(width: 1, height: 16)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { isHovered = $0 }
        .help(tab.url.path)
    }

    @ViewBuilder
    private var background: some View {
        if isActive {
            UnevenRoundedRectangle(topLeadingRadius: 8, topTrailingRadius: 8)
                .fill(Theme.layer.swiftUI)
                .shadow(color: .black.opacity(0.08), radius: 1, y: -0.5)
        } else if isHovered {
            RoundedRectangle(cornerRadius: 6)
                .fill(Theme.subtleHover.swiftUI)
                .padding(.vertical, 3)
        }
    }
}

/// Empty title-bar space that moves the window when dragged.
private struct WindowDragArea: View {
    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(WindowDragGesture())
            .onTapGesture(count: 2) { NSApp.keyWindow?.performZoom(nil) }
    }
}
