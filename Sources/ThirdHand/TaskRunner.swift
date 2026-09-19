import AppKit
import ApplicationServices

@MainActor
protocol TaskRunnerDelegate: AnyObject {
    func taskRunner(_ r: TaskRunner, status: String)
    func taskRunnerDone(_ r: TaskRunner)
    func taskRunnerFailed(_ r: TaskRunner, error: String)
    func taskRunnerCancelled(_ r: TaskRunner)
}

@MainActor
final class TaskRunner {
    private(set) var target: AppTarget
    let goal: String
    let apiKey: String
    weak var delegate: TaskRunnerDelegate?
    private var task: Task<Void, Never>?
    private var history: [ActionHistory] = []
    private let maxSteps = 30
    private var cdpClient: CDPClient?

    init(target: AppTarget, goal: String, apiKey: String) {
        self.target = target
        self.goal = goal
        self.apiKey = apiKey
    }

    func start() { task = Task { await run() } }
    func cancel() {
        task?.cancel()
        delegate?.taskRunnerCancelled(self)
    }

    private func checkFocus() throws {
        try Task.checkCancellation()
        guard !target.application.isTerminated,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid else {
            throw ControllerError.invalid("Stopped because the active app changed. Return to \(target.name) and try again.")
        }
    }

    // MARK: - Main loop

    private func run() async {
        defer { cdpClient?.disconnect(); cdpClient = nil }
        do {
            guard AXIsProcessTrusted() else { throw ControllerError.invalid("Enable Accessibility for Third Hand in System Settings.") }
            target.application.activate()
            try await Task.sleep(nanoseconds: 400_000_000)

            if ElectronDetector.isElectron(target) {
                Log.info("Electron app detected: \(target.name)")
                var port = await ElectronDetector.findDebugPort(pid: target.pid)
                if port == nil {
                    delegate?.taskRunner(self, status: "Restarting \(target.name) for DOM access…")
                    do {
                        port = try await ElectronDetector.relaunchWithDebugging(target: target)
                        try await Task.sleep(nanoseconds: 500_000_000)
                        guard let newTarget = AppTarget.captureCurrentApp(),
                              newTarget.bundleIdentifier == target.bundleIdentifier else {
                            throw ControllerError.invalid("Could not recapture \(target.name) after relaunch")
                        }
                        target = newTarget
                        target.application.activate()
                        try await Task.sleep(nanoseconds: 400_000_000)
                    } catch {
                        Log.info("Electron relaunch failed: \(error.localizedDescription)")
                    }
                }
                if let port {
                    let cdp = CDPClient(port: port)
                    do {
                        try await cdp.connect()
                        cdpClient = cdp
                    } catch {
                        Log.info("CDP connection failed for \(target.name): \(error.localizedDescription)")
                    }
                }
            }

            AXUIElementSetAttributeValue(target.appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            AXUIElementSetAttributeValue(target.appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)

            let jev = JevClient(apiKey: apiKey)
            var previousDecision: AgentDecision?
            var previousObservation = ""
            var repeats = 0
            var pendingObservation: [AccessibilityElement]?

            for _ in 0..<maxSteps {
                try checkFocus()
                delegate?.taskRunner(self, status: "Observing…")
                let observationStart = Date()
                let elements: [AccessibilityElement]
                if let pending = pendingObservation {
                    elements = pending
                } else {
                    elements = try await observe()
                }
                pendingObservation = nil
                Log.info("Timing observation_ms=\(Int(Date().timeIntervalSince(observationStart) * 1000)) cdp=\(cdpClient != nil) count=\(elements.count)")

                let window = WindowSnapshot.frontWindow(pid: target.pid)
                try checkFocus()

                delegate?.taskRunner(self, status: "Thinking…")
                let result = try await jev.decide(goal: goal, elements: elements, appName: target.name, history: history)

                Log.info("Jev done=\(String(format: "%.2f", result.done)) absent=\(String(format: "%.2f", result.absent)) pickedNone=\(result.pickedNone)")
                if result.done >= JevClient.doneThreshold {
                    Log.info("Jev done threshold reached — task complete")
                    delegate?.taskRunnerDone(self); return
                }
                if result.pickedNone && result.absent >= JevClient.absentThreshold {
                    throw ControllerError.invalid("The needed control isn't visible on screen. Try a more specific request or navigate there first.")
                }

                var decision = result.decision

                if decision.operation == "TYPE_TEXT", decision.textValue == nil {
                    if let text = TextExtractor.extract(from: goal) {
                        decision.textValue = text
                    } else {
                        let field = elements.first { String($0.id) == decision.targetIndex }
                        delegate?.taskRunner(self, status: "Figuring out what to type…")
                        decision.textValue = try await jev.buildText(goal: goal, fieldLabel: field?.displayLabel ?? "text field")
                    }
                }
                try decision.validate(elements: elements, hasScreenshot: false)

                try checkFocus()
                let currentWindow = WindowSnapshot.frontWindow(pid: target.pid)
                guard currentWindow?.id == window?.id, currentWindow?.frame == window?.frame else {
                    history.append(ActionHistory(action: "OBSERVE", result: "Window moved or changed; discarded stale action."))
                    continue
                }

                let observation = elements.map { $0.compactDescription() }.joined(separator: "\n")
                if sameAction(decision, previousDecision) && observation == previousObservation { repeats += 1 } else { repeats = 0 }
                previousDecision = decision
                previousObservation = observation
                guard repeats < 3 else { throw ControllerError.invalid("Stopped after repeated actions without progress. Try a more specific request.") }

                switch decision.operation {
                case "DONE": delegate?.taskRunnerDone(self); return
                case "BLOCKED": throw ControllerError.invalid(decision.reason ?? "Cannot continue with the available controls.")
                default: break
                }

                delegate?.taskRunner(self, status: decision.operation == "TYPE_TEXT" ? "Entering text…" : "Working in \(target.name)…")
                do {
                    try await execute(decision, elements: elements, windowFrame: window?.frame)
                    history.append(ActionHistory(action: describe(decision), result: "Input sent; verify the next observation."))
                } catch is CancellationError { throw CancellationError() }
                catch {
                    try checkFocus()
                    history.append(ActionHistory(action: describe(decision), result: error.localizedDescription))
                }
                pendingObservation = try await waitForChange(from: observation)
            }
            throw ControllerError.invalid("Reached the 30-step limit. Try splitting the request into smaller tasks.")
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled else { return }
            delegate?.taskRunnerFailed(self, error: error.localizedDescription)
        }
    }

    // MARK: - Observation (CDP → AX → Vision OCR)

    private func observe() async throws -> [AccessibilityElement] {
        if let cdp = cdpClient {
            do { return try await cdp.extractElements() }
            catch {
                Log.info("CDP observation failed, falling back to AX: \(error.localizedDescription)")
                cdpClient?.disconnect()
                cdpClient = nil
            }
        }
        let axElements = AXTreeWalker.walk(target: target)
        if !JevClient.targets(axElements).isEmpty { return axElements }
        do {
            let visionElements = try await VisionObserver.observe(pid: target.pid)
            if !visionElements.isEmpty { return visionElements }
        } catch {
            Log.info("Vision fallback failed: \(error.localizedDescription)")
        }
        return axElements
    }

    private func waitForChange(from previous: String) async throws -> [AccessibilityElement] {
        let deadline = Date().addingTimeInterval(cdpClient != nil ? 0.15 : 0.3)
        var observed: [AccessibilityElement] = []
        repeat {
            try await Task.sleep(nanoseconds: 40_000_000)
            try checkFocus()
            observed = try await observe()
            if observed.map({ $0.compactDescription() }).joined(separator: "\n") != previous { break }
        } while Date() < deadline
        return observed
    }

    // MARK: - Helpers

    private func sameAction(_ lhs: AgentDecision, _ rhs: AgentDecision?) -> Bool {
        guard var rhs else { return false }
        var lhs = lhs
        lhs.reason = nil
        rhs.reason = nil
        return lhs == rhs
    }

    private func describe(_ decision: AgentDecision) -> String {
        "\(decision.operation) target=\(decision.targetIndex ?? "none") text=\(decision.textValue ?? "") key=\(decision.key ?? "")"
    }

    // MARK: - Execution

    private func execute(_ decision: AgentDecision, elements: [AccessibilityElement], windowFrame: CGRect?) async throws {
        let element = elements.first { String($0.id) == decision.targetIndex }
        let point: CGPoint?
        if let element, let frame = element.screenFrame() {
            point = CGPoint(x: frame.midX, y: frame.midY)
        } else { point = nil }
        func click(count: Int = 1, right: Bool = false) throws {
            guard let point, let windowFrame, windowFrame.contains(point) else { throw ControllerError.invalid("Target is outside the current window") }
            try InputController.click(point, count: count, right: right)
        }
        switch decision.operation {
        case "CLICK":
            if let element, let ax = element.axElement {
                for action in ["AXPress", "AXOpen", "AXConfirm", "AXPick"] where element.actions.contains(action) {
                    if AXUIElementPerformAction(ax, action as CFString) == .success { return }
                }
            }
            try click()
        case "DOUBLE_CLICK": try click(count: 2)
        case "RIGHT_CLICK": try click(right: true)
        case "TYPE_TEXT":
            guard let text = decision.textValue else { throw ControllerError.invalid("Missing text") }
            if point == nil, let element, let ax = element.axElement {
                AXUIElementSetAttributeValue(ax, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                if AXUIElementSetAttributeValue(ax, kAXValueAttribute as CFString, text as CFTypeRef) == .success {
                    var actual: CFTypeRef?
                    AXUIElementCopyAttributeValue(ax, kAXValueAttribute as CFString, &actual)
                    if actual as? String == text { return }
                }
            }
            try click()
            try await Task.sleep(nanoseconds: 150_000_000)
            try checkFocus()
            try InputController.press("a", modifiers: ["command"])
            try await Task.sleep(nanoseconds: 80_000_000)
            try checkFocus()
            try InputController.type(text)
        case "KEY_PRESS": try InputController.press(decision.key!, modifiers: decision.modifiers ?? [])
        case "SCROLL_UP", "SCROLL_DOWN":
            guard let frame = windowFrame else { throw ControllerError.invalid("No window to scroll") }
            try InputController.scroll(decision.operation == "SCROLL_UP" ? 5 : -5,
                                       at: point ?? CGPoint(x: frame.midX, y: frame.midY))
        case "WAIT": try await Task.sleep(nanoseconds: 700_000_000)
        default: throw ControllerError.invalid("Unsupported operation")
        }
    }
}
