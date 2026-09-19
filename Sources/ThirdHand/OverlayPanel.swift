import AppKit
import SwiftUI

final class OverlayPanel: NSPanel {
    private let onSubmit: (String) -> Void
    private let onCancel: () -> Void

    init(
        target: AppTarget,
        prompt: String = "What should I do?",
        onSubmit: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.onSubmit = onSubmit
        self.onCancel = onCancel

        let frame = target.windowFrame ?? NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 800, height: 600)

        super.init(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        level = .floating
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        setupLayers(target: target, prompt: prompt)
    }

    private func setupLayers(target: AppTarget, prompt: String) {
        guard let cv = contentView else { return }

        // Clip every overlay layer, including the dimming view, to the window edge.
        let cornerRadius: CGFloat = 12
        cv.wantsLayer = true
        cv.layer?.cornerRadius = cornerRadius
        cv.layer?.masksToBounds = true

        let blur = NSVisualEffectView(frame: cv.bounds)
        blur.autoresizingMask = [.width, .height]
        blur.blendingMode = .behindWindow
        blur.material = .hudWindow
        blur.state = .active
        blur.appearance = NSAppearance(named: .darkAqua)
        // Behind-window blur is composited separately; mask the effect itself too.
        let maskSize = NSSize(width: cornerRadius * 2 + 2, height: cornerRadius * 2 + 2)
        let mask = NSImage(size: maskSize, flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius).fill()
            return true
        }
        mask.capInsets = NSEdgeInsets(top: cornerRadius, left: cornerRadius,
                                     bottom: cornerRadius, right: cornerRadius)
        mask.resizingMode = .stretch
        blur.maskImage = mask
        cv.addSubview(blur)

        let dark = NSView(frame: cv.bounds)
        dark.autoresizingMask = [.width, .height]
        dark.wantsLayer = true
        dark.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.35).cgColor
        cv.addSubview(dark)

        let swiftUI = OverlayInputView(
            appName: target.name,
            appIcon: target.icon,
            prompt: prompt,
            onSubmit: { [weak self] text in self?.onSubmit(text) },
            onCancel: { [weak self] in self?.onCancel() }
        )
        let host = NSHostingView(rootView: swiftUI)
        host.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(host)

        NSLayoutConstraint.activate([
            host.centerXAnchor.constraint(equalTo: cv.centerXAnchor),
            host.centerYAnchor.constraint(equalTo: cv.centerYAnchor),
            host.widthAnchor.constraint(lessThanOrEqualTo: cv.widthAnchor, constant: -60),
        ])
    }

    func show() {
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel()
    }

    override var canBecomeKey: Bool { true }
}

// MARK: - SwiftUI Input

private struct OverlayInputView: View {
    let appName: String
    let appIcon: NSImage?
    let prompt: String
    let onSubmit: (String) -> Void
    let onCancel: () -> Void

    @State private var input = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 8) {
                if let icon = appIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 20, height: 20)
                        .cornerRadius(4)
                }
                Text(appName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white.opacity(0.45))
            }

            VStack(alignment: .leading, spacing: 10) {
                Text(prompt)
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.35))

                TextField("", text: $input)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .foregroundColor(.white)
                    .focused($focused)
                    .onSubmit {
                        let t = input.trimmingCharacters(in: .whitespaces)
                        guard !t.isEmpty else { return }
                        onSubmit(t)
                    }
            }
            .padding(20)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.white.opacity(0.07))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
            )
            .frame(width: 420)
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { focused = true }
        }
        .onExitCommand { onCancel() }
    }
}
