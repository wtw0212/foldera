import AppKit
import SwiftUI

/// Floating progress window for copies and moves, like Explorer's "N% complete" dialog.
/// It only appears when a transfer takes longer than a moment.
final class TransferWindow {
    static let shared = TransferWindow()

    private var panel: NSPanel?
    private var showTask: Task<Void, Never>?

    private init() {}

    func scheduleShow() {
        guard showTask == nil, panel?.isVisible != true else { return }
        showTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            showTask = nil
            guard !Task.isCancelled, !FileTransfers.shared.active.isEmpty else { return }
            show()
        }
    }

    func hideIfIdle() {
        guard FileTransfers.shared.active.isEmpty else { return }
        showTask?.cancel()
        showTask = nil
        panel?.orderOut(nil)
    }

    func updateTitle() {
        panel?.title = L10n.text("File operations")
    }

    private func show() {
        if panel == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 440, height: 160),
                styleMask: [.titled, .closable, .utilityWindow, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            panel.title = L10n.text("File operations")
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.contentView = NSHostingView(rootView: TransferList())
            panel.center()
            self.panel = panel
        }
        panel?.orderFront(nil)
        updateTitle()
    }
}

private struct TransferList: View {
    @State private var transfers = FileTransfers.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(transfers.active) { transfer in
                TransferRow(transfer: transfer)
            }
        }
        .padding(16)
        .frame(width: 440, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .environment(\.locale, L10n.locale)
        .onChange(of: AppSettings.shared.language) { TransferWindow.shared.updateTitle() }
    }
}

struct TransferRow: View {
    let transfer: FileTransfer

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(transfer.title)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            HStack {
                Text(L10n.format("%lld%% complete", Int(transfer.fraction * 100)))
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                Button {
                    transfer.cancel()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(SubtleButtonStyle(padding: EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4)))
                .help(L10n.text("Cancel"))
                .disabled(transfer.isCancelled)
            }
            ProgressView(value: transfer.fraction)
                .progressViewStyle(.linear)
                .tint(Color(nsColor: .init(hex: 0x06B025)))
            HStack {
                Text(L10n.format("Name: %@", transfer.currentName))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if transfer.bytesPerSecond > 0 {
                    Text(L10n.format("Speed: %@/s", FileFormat.totalSize(Int64(transfer.bytesPerSecond))))
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            Text(remainingText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private var remainingText: String {
        let remaining = max(0, transfer.totalBytes - transfer.completedBytes)
        var text = L10n.format("Remaining: %@", FileFormat.totalSize(remaining))
        if transfer.bytesPerSecond > 0 {
            let seconds = Double(remaining) / transfer.bytesPerSecond
            let formatter = DateComponentsFormatter()
            var calendar = Calendar.current
            calendar.locale = L10n.locale
            formatter.calendar = calendar
            formatter.unitsStyle = .abbreviated
            formatter.allowedUnits = seconds > 3600 ? [.hour, .minute] : [.minute, .second]
            if let time = formatter.string(from: seconds) { text += L10n.format(" · about %@ left", time) }
        }
        return transfer.isCancelled ? L10n.text("Cancelling…") : text
    }
}
