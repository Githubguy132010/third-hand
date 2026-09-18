import AppKit
import ApplicationServices

final class AppDelegate: NSObject, NSApplicationDelegate, TaskRunnerDelegate, ObservableObject {
    private var hotkeyManager: HotkeyManager?
    private var overlayPanel: OverlayPanel?
    private var taskRunner: TaskRunner?
    private var statusWindow: StatusIndicatorWindow?
    private var currentTarget: AppTarget?
    private var didStart = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        Log.info("applicationWillFinishLaunching")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.info("applicationDidFinishLaunching — starting services")
        guard !didStart else { return }
        didStart = true

        hotkeyManager = HotkeyManager { [weak self] in
            self?.handleHotkey()
        }
        hotkeyManager?.start()
        Log.info("hotkey started")

        if !AXIsProcessTrusted() {
            Log.info("AX not trusted, prompting")
            promptAccessibility()
        } else {
            Log.info("AX trusted")
        }

        let hasKey = KeychainHelper.getAPIKey() != nil
        Log.info("hasKey=\(hasKey)")
        if !hasKey {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.promptAPIKey() }
        }

        Log.info("setup done")
    }

    // MARK: - Hotkey

    @objc func handleHotkey() {
        Log.info("Hotkey fired")
        if overlayPanel != nil { dismissOverlay(); return }
        if taskRunner != nil { taskRunner?.cancel(); statusWindow?.dismiss(); taskRunner = nil; return }

        guard KeychainHelper.getAPIKey() != nil else { Log.info("No API key"); promptAPIKey(); return }
        guard let target = AppTarget.captureCurrentApp() else { Log.info("No target app"); return }

        currentTarget = target
        showOverlay(for: target)
    }

    // MARK: - Overlay

    private func showOverlay(for target: AppTarget, prompt: String = "What should I do?") {
        dismissOverlay()
        overlayPanel = OverlayPanel(
            target: target,
            prompt: prompt,
            onSubmit: { [weak self] task in
                self?.dismissOverlay()
                self?.startTask(task)
            },
            onCancel: { [weak self] in
                self?.dismissOverlay()
                self?.reactivateTarget()
            }
        )
        overlayPanel?.show()
    }

    private func dismissOverlay() {
        overlayPanel?.close()
        overlayPanel = nil
    }

    private func reactivateTarget() {
        currentTarget?.application.activate()
    }

    // MARK: - Task execution

    private func startTask(_ task: String) {
        guard let target = currentTarget, let apiKey = KeychainHelper.getAPIKey() else { return }

        let client = JevClient(apiKey: apiKey)
        let runner = TaskRunner(target: target, goal: task, client: client)
        runner.delegate = self
        taskRunner = runner

        statusWindow = StatusIndicatorWindow(near: target) { [weak self] in
            self?.taskRunner?.cancel()
        }

        runner.start()
    }

    // MARK: - TaskRunnerDelegate

    func taskRunner(_ r: TaskRunner, status: String) {
        statusWindow?.updateStatus(status)
    }

    func taskRunnerDone(_ r: TaskRunner) {
        statusWindow?.showDone()
        taskRunner = nil
    }

    func taskRunnerFailed(_ r: TaskRunner, error: String) {
        Log.info("FAILED: \(error)")
        statusWindow?.showError(error)
        taskRunner = nil
    }

    func taskRunnerNeedsInput(_ r: TaskRunner, prompt: String, completion: @escaping (String?) -> Void) {
        guard let target = currentTarget else { completion(nil); return }
        overlayPanel = OverlayPanel(
            target: target,
            prompt: prompt,
            onSubmit: { [weak self] text in
                self?.dismissOverlay()
                self?.reactivateTarget()
                completion(text)
            },
            onCancel: { [weak self] in
                self?.dismissOverlay()
                self?.reactivateTarget()
                completion(nil)
            }
        )
        overlayPanel?.show()
    }

    // MARK: - Onboarding

    @objc func promptAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(opts)
        if !trusted {
            let a = NSAlert()
            a.messageText = "Accessibility Required"
            a.informativeText = "After toggling Third Hand ON in System Settings → Privacy & Security → Accessibility, quit and relaunch the app."
            a.addButton(withTitle: "OK")
            NSApp.activate(ignoringOtherApps: true)
            a.runModal()
        }
    }

    @objc func promptAPIKey() {
        let alert = NSAlert()
        alert.messageText = "Enter API Key"
        alert.informativeText = "Stored in macOS Keychain. OpenRouter or TypeSafe key."
        alert.alertStyle = .informational

        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "sk-or-..."
        if let existing = KeychainHelper.getAPIKey() { field.stringValue = existing }
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            let k = field.stringValue.trimmingCharacters(in: .whitespaces)
            if !k.isEmpty { KeychainHelper.saveAPIKey(k) }
        }
    }
}
