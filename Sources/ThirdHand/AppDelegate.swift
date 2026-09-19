import AppKit
import ApplicationServices
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, TaskRunnerDelegate, ObservableObject {
    private var hotkeyManager: HotkeyManager?
    private var overlayPanel: OverlayPanel?
    private var taskRunner: TaskRunner?
    private var statusWindow: StatusIndicatorWindow?
    private var currentTarget: AppTarget?
    private var didStart = false
    private var setupWindow: NSWindow?
    private var permissionTimer: Timer?
    private var apiKey: String?
    @Published var accessibilityReady = false
    @Published var shortcutReady = false
    @Published var screenReady = false
    @Published var keyReady = false

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
        showSetup()
        refreshPermissions()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshPermissions() }
        }
        // Read once, outside hotkey handling: a Keychain prompt can steal app focus.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.apiKey = KeychainHelper.getAPIKey()
            self.keyReady = self.apiKey != nil
        }

        Log.info("setup done")
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSetup()
        return true
    }

    func showSetup() {
        if setupWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 510, height: 370),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Third Hand"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SetupView(delegate: self))
            window.center()
            setupWindow = window
        }
        setupWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func refreshPermissions() {
        accessibilityReady = AXIsProcessTrusted()
        screenReady = CGPreflightScreenCaptureAccess()
        if accessibilityReady && hotkeyManager?.isRunning == false { hotkeyManager?.start() }
        if !accessibilityReady && hotkeyManager?.isRunning == true { hotkeyManager?.stop() }
        shortcutReady = hotkeyManager?.isRunning == true
    }

    func openPrivacySettings(_ section: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?" + section) {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Hotkey

    @objc func handleHotkey() {
        Log.info("Hotkey fired")
        guard AXIsProcessTrusted() else { showSetup(); return }
        if overlayPanel != nil { dismissOverlay(); return }
        if taskRunner != nil { taskRunner?.cancel(); statusWindow?.dismiss(); taskRunner = nil; return }

        guard apiKey != nil else { Log.info("No API key"); promptAPIKey(); return }
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
        guard let target = currentTarget, let apiKey else { return }

        let runner = TaskRunner(target: target, goal: task, apiKey: apiKey)
        runner.delegate = self
        taskRunner = runner

        statusWindow = StatusIndicatorWindow(near: target) { [weak self] in
            self?.taskRunner?.cancel()
        }

        runner.start()
    }

    // MARK: - TaskRunnerDelegate

    func taskRunner(_ r: TaskRunner, status: String) {
        guard taskRunner === r else { return }
        statusWindow?.updateStatus(status)
    }

    func taskRunnerDone(_ r: TaskRunner) {
        guard taskRunner === r else { return }
        statusWindow?.showDone()
        taskRunner = nil
    }

    func taskRunnerFailed(_ r: TaskRunner, error: String) {
        guard taskRunner === r else { return }
        Log.info("FAILED: \(error)")
        statusWindow?.showError(error)
        taskRunner = nil
    }

    func taskRunnerCancelled(_ r: TaskRunner) {
        guard taskRunner === r else { return }
        statusWindow?.dismiss()
        taskRunner = nil
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
        alert.informativeText = "Jev API key (TypeSafe), stored in macOS Keychain. Element labels are sent to select the right control; no screenshots or full-page text leave the device."
        alert.alertStyle = .informational

        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "apikey_..."
        if let existing = apiKey { field.stringValue = existing }
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            let k = field.stringValue.trimmingCharacters(in: .whitespaces)
            if !k.isEmpty {
                do {
                    try KeychainHelper.saveAPIKey(k)
                    apiKey = k
                    keyReady = true
                }
                catch {
                    let failure = NSAlert()
                    failure.messageText = "Could not save API key"
                    failure.informativeText = error.localizedDescription
                    failure.runModal()
                }
            }
        }
    }
}

private struct SetupView: View {
    @ObservedObject var delegate: AppDelegate

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Third Hand is running").font(.title2.bold())
            Text("Switch to Spotify, Blender, or another app, then press Control–Space. You can close this window; Third Hand stays in the menu bar.")
            HStack {
                Text(delegate.accessibilityReady ? "✓ Accessibility enabled" : "Accessibility access needed")
                Spacer()
                Button("Open Settings") { delegate.openPrivacySettings("Privacy_Accessibility") }
            }
            HStack {
                Text(delegate.screenReady ? "✓ Screen Recording enabled" : "Screen Recording needed for visual control")
                Spacer()
                Button("Open Settings") { delegate.openPrivacySettings("Privacy_ScreenCapture") }
            }
            HStack {
                Text(delegate.keyReady ? "✓ API key loaded" : "API key needs setup or Keychain approval")
                Spacer()
                Button("Set API Key…") { delegate.promptAPIKey() }
            }
            Text(delegate.shortcutReady ? "✓ Control–Space is ready" : "Shortcut waiting for Accessibility access")
                .foregroundStyle(.secondary)
            Divider()
            Text("Running copy: " + Bundle.main.bundlePath)
                .font(.caption).textSelection(.enabled)
            Text("If access stopped after an update, remove the old Accessibility entry and add this copy again.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 510)
    }
}
