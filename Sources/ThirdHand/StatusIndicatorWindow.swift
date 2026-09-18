import AppKit
import SwiftUI

final class StatusIndicatorWindow: NSPanel {
    private var hosting: NSHostingView<StatusView>!
    private var currentText = "Working…"
    private var cancelAction: (() -> Void)?

    init(near target: AppTarget, onCancel: @escaping () -> Void) {
        self.cancelAction = onCancel

        let size = NSSize(width: 220, height: 34)
        let wf = target.windowFrame ?? NSScreen.main?.frame ?? .zero
        let origin = NSPoint(x: wf.maxX - size.width - 12, y: wf.maxY - size.height - 12)

        super.init(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        level = .floating
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let view = StatusView(text: currentText, showSpinner: true, onCancel: onCancel)
        hosting = NSHostingView(rootView: view)
        hosting.frame = contentView!.bounds
        hosting.autoresizingMask = [.width, .height]
        contentView?.addSubview(hosting)
    }

    func updateStatus(_ text: String) {
        currentText = text
        hosting.rootView = StatusView(text: text, showSpinner: true, onCancel: cancelAction ?? {})
        if !isVisible { orderFront(nil) }
    }

    func showDone() {
        hosting.rootView = StatusView(text: "✓ Done", showSpinner: false, onCancel: {})
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.dismiss()
        }
    }

    func showError(_ msg: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(msg, forType: .string)
        hosting.rootView = StatusView(text: "✗ Error copied to clipboard", showSpinner: false, onCancel: {})
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.dismiss()
        }
    }

    func dismiss() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            animator().alphaValue = 0
        }, completionHandler: {
            self.orderOut(nil)
            self.alphaValue = 1
        })
    }
}

private struct StatusView: View {
    let text: String
    let showSpinner: Bool
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if showSpinner {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
            }
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.85))
                .lineLimit(1)
            Spacer()
            if showSpinner {
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white.opacity(0.4))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.black.opacity(0.78))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
        )
    }
}
