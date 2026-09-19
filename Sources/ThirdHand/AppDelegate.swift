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
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 470),
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

    private var lastPermissionState = ""

    private func refreshPermissions() {
        accessibilityReady = AXIsProcessTrusted()
        screenReady = CGPreflightScreenCaptureAccess()
        let permissionState = "accessibility=\(accessibilityReady) screenRecording=\(screenReady)"
        if permissionState != lastPermissionState { Log.info("Permissions " + permissionState); lastPermissionState = permissionState }
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

        statusWindow?.dismiss()
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
        Log.info("Task stopped; blocker displayed in status panel")
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
        if !AXIsProcessTrustedWithOptions(opts) { openPrivacySettings("Privacy_Accessibility") }
        refreshPermissions()
    }

    func promptScreenRecording() {
        if !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }
        if !CGPreflightScreenCaptureAccess() { openPrivacySettings("Privacy_ScreenCapture") }
        refreshPermissions()
    }

    @objc func promptAPIKey() {
        let alert = NSAlert()
        alert.messageText = "Enter API Key"
        alert.informativeText = "Jev API key (TypeSafe), stored in macOS Keychain. The goal, observed accessibility text, and recent action results are sent to TypeSafe. Screenshots and OCR processing stay on this Mac. Jev selects text from your request; free-form writing is not supported. Jev remains a remote text-only service."
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
            HStack(spacing: 12) {
                Image(nsImage: NSApplication.shared.applicationIconImage).resizable().frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Third Hand").font(.title2.bold())
                    Text(delegate.accessibilityReady && delegate.keyReady ? "Ready when you are" : "Let’s get set up")
                        .foregroundStyle(.secondary)
                }
            }
            Text("Switch to Spotify, Blender, or another app, then press Control–Space. You can close this window; Third Hand stays in the menu bar.")
            HStack {
                Text(delegate.accessibilityReady ? "✓ Accessibility enabled" : "Accessibility access needed")
                Spacer()
                Button(delegate.accessibilityReady ? "Settings…" : "Enable…") {
                    if delegate.accessibilityReady { delegate.openPrivacySettings("Privacy_Accessibility") }
                    else { delegate.promptAccessibility() }
                }
            }
            HStack {
                Text(delegate.screenReady ? "✓ Screen Recording enabled" : "Screen Recording needed for local OCR")
                Spacer()
                Button(delegate.screenReady ? "Settings…" : "Enable…") {
                    if delegate.screenReady { delegate.openPrivacySettings("Privacy_ScreenCapture") }
                    else { delegate.promptScreenRecording() }
                }
            }
            HStack {
                Text(delegate.keyReady ? "✓ API key loaded" : "API key needs setup or Keychain approval")
                Spacer()
                Button("Set API Key…") { delegate.promptAPIKey() }
            }
            Text("Screen reading stays on-device. Jev selects actions and text from your request.")
                .font(.caption).foregroundStyle(.secondary)
            Text(delegate.shortcutReady ? "✓ Control–Space is ready" : "Shortcut waiting for Accessibility access")
                .foregroundStyle(.secondary)
            Divider()
            Text("If macOS asks you to quit and reopen after enabling access, reopen this copy of Third Hand.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Show App in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }
                .font(.caption)
        }
        .padding(24)
        .frame(width: 540)
    }
}
