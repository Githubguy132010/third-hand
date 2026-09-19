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
    let target: AppTarget
    let goal: String
    let apiKey: String
    weak var delegate: TaskRunnerDelegate?
    private var task: Task<Void, Never>?
    private var history: [ActionHistory] = []
    private let maxSteps = 30
    private var cdpClient: CDPClient?
    private var active = false
    private var useOCR = false
    private var progress = RunProgress()
    private var phase = "starting"
    private var terminalEntrySent = false

    init(target: AppTarget, goal: String, apiKey: String) {
        self.target = target
        self.goal = goal
        self.apiKey = apiKey
    }

    func start() {
        guard task == nil else { return }
        active = true
        task = Task { await run() }
    }
    func cancel() {
        active = false
        task?.cancel()
        Log.info("Task cancelled phase=\(phase)")
        cdpClient?.disconnect()
        delegate?.taskRunnerCancelled(self)
    }

    private func checkFocus() throws {
        try Task.checkCancellation()
        guard active else { throw CancellationError() }
        guard !target.application.isTerminated,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid else {
            Log.info("Task focus lost phase=\(phase)")
            throw ControllerError.invalid("Stopped because the active app changed. Return to \(target.name) and try again.")
        }
    }

    private func run() async {
        defer { active = false; cdpClient?.disconnect(); cdpClient = nil }
        do {
            try await AsyncTimeout.run(seconds: 180, message: "Stopped after three minutes. The task has not been verified complete.", onTimeout: {
                self.active = false
                self.cdpClient?.disconnect()
            }) { try await self.runLoop() }
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled else { return }
            let diagnostic = error as NSError
            Log.info("Task failed phase=\(phase) error_type=\(String(reflecting: type(of: error))) error_code=\(diagnostic.code)")
            delegate?.taskRunnerFailed(self, error: error.localizedDescription)
        }
    }

    private func runLoop() async throws {
        guard AXIsProcessTrusted() else { throw ControllerError.invalid("Enable Accessibility for Third Hand in System Settings.") }
        target.application.activate()
        try await Task.sleep(nanoseconds: 400_000_000)
        try checkFocus()
        if ElectronDetector.isElectron(target), let window = WindowSnapshot.frontWindow(pid: target.pid),
           let port = await ElectronDetector.findDebugPort(pid: target.pid) {
            try checkFocus()
            let cdp = CDPClient(port: port)
            do { try await cdp.connect(windowFrame: window.frame); cdpClient = cdp }
            catch { cdp.disconnect(); Log.info("Existing browser connection unavailable; using accessibility") }
        }
        try checkFocus()
        AXUIElementSetAttributeValue(target.appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(target.appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        let jev = JevClient(apiKey: apiKey)
        var actions = 0

        // Separate observation budget permits a final verification after the last action,
        // while bounding stale-window retries and recovery iterations too.
        for _ in 0..<40 {
            try checkFocus()
            delegate?.taskRunner(self, status: "Observing… (\(actions)/\(maxSteps))")
            phase = "observing"
            var observation = try await observe()
            if !useOCR && JevClient.targets(observation.elements).isEmpty {
                try recover("No usable controls were exposed by the app.")
                observation = try await observe()
            }
            try checkFocus()
            delegate?.taskRunner(self, status: actions == maxSteps ? "Checking the result…" : "Thinking… (\(actions)/\(maxSteps))")
            var decision: AgentDecision
            do {
                phase = "selecting_action"
                let result = try await jev.decide(goal: goal, elements: observation.elements, appName: target.name, history: history)
                Log.info("Decision operation=\(result.decision.operation) done=\(result.done) absent=\(result.absent)")
                decision = result.done >= JevClient.doneThreshold
                    ? AgentDecision(operation: "DONE") : result.decision
            } catch is CancellationError { throw CancellationError() }
            catch let error as JevServiceError { throw error }
            catch {
                try checkFocus()
                try recover("Action selection failed: \(error.localizedDescription)")
                continue
            }
            try checkFocus()
            guard isCurrent(observation) else {
                history.append(ActionHistory(action: "OBSERVE", result: "Window moved or changed; discarded stale decision."))
                continue
            }
            if decision.operation == "DONE" {
                // Re-observe independently: neither input sent nor a confidence score alone is completion.
                let fresh = try await observe()
                try checkFocus()
                phase = "confirming_completion"
                let confirmed = try await jev.confirmCompletion(goal: goal, elements: fresh.elements,
                                                               appName: target.name, history: history)
                try checkFocus()
                guard isCurrent(fresh) else {
                    throw ControllerError.invalid("The window changed during completion checking. Stopped without sending more input.")
                }
                if confirmed { Log.info("Task completed verified=true"); delegate?.taskRunnerDone(self); return }
                // Once completion is plausible, further clicks could undo the result (e.g. pause playback).
                throw ControllerError.invalid("The action may be complete, but the final check was inconclusive. Stopped without sending more input.")
            }
            guard actions < maxSteps else {
                throw ControllerError.invalid("Stopped after \(maxSteps) actions. The final screen does not confirm completion.")
            }
            if decision.operation == "BLOCKED" {
                try recover(decision.reason ?? "The next control is not visible.")
                continue
            }
            if decision.operation == "TYPE_TEXT", decision.textValue == nil {
                guard let field = observation.elements.first(where: { String($0.id) == decision.targetIndex }) else {
                    throw ControllerError.invalid("No editable field was selected.")
                }
                guard !terminalEntrySent else {
                    throw ControllerError.invalid("Terminal input was already sent. Stopped rather than entering the command again without a verified result.")
                }
                delegate?.taskRunner(self, status: "Choosing text…")
                phase = "selecting_text"
                let plan = try await jev.selectText(goal: goal, field: field, appName: target.name,
                                                   terminal: TextEntryPlan.isTerminal(target.bundleIdentifier))
                decision.textValue = plan.text
                Log.info("Text entry intent=\(plan.kind)")
            }
            phase = "validating_action"
            try decision.validate(elements: observation.elements, hasScreenshot: false)
            try checkFocus()
            guard isCurrent(observation) else { continue }
            // Revalidate the chosen control after model/text latency, even if the window stayed still.
            if let targetID = decision.targetIndex,
               let original = observation.elements.first(where: { String($0.id) == targetID }) {
                phase = "revalidating_target"
                let fresh = try await observe()
                guard fresh.windowID == observation.windowID, fresh.frame == observation.frame,
                      let current = ObservationState.matching(original, in: fresh.elements), current.enabled,
                      current.frame == original.frame else {
                    history.append(ActionHistory(action: "OBSERVE", result: "Selected control changed while planning; discarded action."))
                    continue
                }
                decision.targetIndex = String(current.id)
                observation = fresh
            }
            try checkFocus()
            guard isCurrent(observation) else { continue }
            try decision.validate(elements: observation.elements, hasScreenshot: false)
            if decision.operation == "TYPE_TEXT", !TextEntryPlan.isTerminal(target.bundleIdentifier),
               let field = observation.elements.first(where: { String($0.id) == decision.targetIndex }),
               field.value == decision.textValue {
                history.append(ActionHistory(action: "SKIP_TYPE", result: "The selected field already contains the requested text. Submit it or choose a different action; do not retype it."))
                if history.suffix(3).allSatisfy({ $0.action == "SKIP_TYPE" }), history.count >= 3 {
                    throw ControllerError.invalid("The field already contains the requested text, but no next step was selected.")
                }
                continue
            }
            if let problem = progress.problem(decision: decision, elements: observation.elements) {
                try recover(problem)
                continue
            }
            delegate?.taskRunner(self, status: "\(decision.operation == "TYPE_TEXT" ? "Entering text" : "Working")… (\(actions + 1)/\(maxSteps))")
            actions += 1
            phase = "executing_\(decision.operation)"
            var executionError: String?
            do { try await execute(decision, elements: observation.elements, windowFrame: observation.frame) }
            catch is CancellationError { throw CancellationError() }
            catch {
                try checkFocus()
                executionError = error.localizedDescription
                let reason = (error as? TextFieldFocus.Failure)?.rawValue ?? "input_error"
                Log.info("Action execution failed operation=\(decision.operation) reason=\(reason)")
            }
            delegate?.taskRunner(self, status: "Checking the action…")
            phase = "verifying_\(decision.operation)"
            let after = try await settle(after: decision, before: observation)
            try checkFocus()
            var verification = ObservationState.verify(decision, before: observation.elements, after: after.elements)
            if let executionError {
                verification = ActionVerification(verified: false, detail: "Execution failed: \(executionError)")
            }
            try checkFocus()
            if !isCurrent(after) { verification = ActionVerification(verified: false, detail: "Window changed during verification; result is unverified.") }
            if TextEntryPlan.isTerminal(target.bundleIdentifier), decision.operation == "TYPE_TEXT", executionError == nil {
                verification = ActionVerification(verified: false, detail: "Terminal input sent once, awaiting submission and command output. Do not retype. Select Return to submit if appropriate, then verify the result.")
            }
            progress.record(verification)
            history.append(ActionHistory(action: describe(decision, elements: observation.elements), result: verification.detail))
            Log.info("Action step=\(actions) operation=\(decision.operation) verified=\(verification.verified) ocr=\(useOCR)")
        }
        throw ControllerError.invalid("Stopped because the app kept changing before actions could be verified.")
    }

    private func recover(_ reason: String) throws {
        phase = "recovery"
        Log.info("Task recovery already_used=\(useOCR)")
        try checkFocus()
        guard progress.beginRecovery(), !useOCR else {
            throw ControllerError.invalid("Stopped: \(reason) The recovery attempt did not resolve the blocker.")
        }
        guard CGPreflightScreenCaptureAccess() else {
            throw ControllerError.invalid("Stopped: \(reason) Enable Screen Recording for Third Hand, then relaunch, to read missing screen labels locally.")
        }
        cdpClient?.disconnect()
        cdpClient = nil
        useOCR = true
        history.append(ActionHistory(action: "RECOVER", result: reason + " Added on-device OCR text from the current window. OCR regions are text, not proven controls. Choose a different strategy."))
        delegate?.taskRunner(self, status: "Reading screen text locally…")
    }

    private struct Observation {
        let elements: [AccessibilityElement]
        let windowID: CGWindowID
        let frame: CGRect
    }

    private func isCurrent(_ observation: Observation) -> Bool {
        guard let window = WindowSnapshot.frontWindow(pid: target.pid) else { return false }
        return window.id == observation.windowID && window.frame == observation.frame
    }

    private func observe() async throws -> Observation {
        try checkFocus()
        guard let window = WindowSnapshot.frontWindow(pid: target.pid) else { throw ControllerError.invalid("No visible target window") }
        var elements: [AccessibilityElement] = []
        if let cdp = cdpClient {
            do { elements = try await cdp.extractElements() }
            catch is CancellationError { throw CancellationError() }
            catch { cdp.disconnect(); cdpClient = nil; Log.info("Browser observation unavailable; using accessibility") }
        }
        if elements.isEmpty { elements = AXTreeWalker.walk(target: target) }
        try checkFocus()
        if useOCR {
            let ocr = try await AsyncTimeout.run(seconds: 8, message: "Local screen reading timed out.") {
                try await VisionObserver.observe(pid: self.target.pid)
            }
            elements = VisionObserver.merging(ocr: ocr, with: elements)
        }
        try checkFocus()
        let result = Observation(elements: elements, windowID: window.id, frame: window.frame)
        guard isCurrent(result) else {
            throw ControllerError.invalid("Window changed during observation. Start again in the intended window.")
        }
        Log.info("Observation window=\(window.id) width=\(Int(window.frame.width)) height=\(Int(window.frame.height)) count=\(elements.count) capped=\(elements.count >= 500) ocr=\(useOCR)")
        return result
    }

    private func settle(after decision: AgentDecision, before: Observation) async throws -> Observation {
        let clock = ContinuousClock()
        let start = clock.now
        let deadline = start.advanced(by: .seconds(2.5))
        var previous = ObservationState.signature(before.elements)
        var stableSince = start
        var latest = before
        repeat {
            try await Task.sleep(nanoseconds: 150_000_000)
            latest = try await observe()
            let signature = ObservationState.signature(latest.elements)
            if signature != previous { previous = signature; stableSince = clock.now }
            // Don't accept the first intermediate redraw. Require a quiet interval,
            // and allow slower submissions/navigation at least one second.
            if clock.now - start >= .seconds(1), clock.now - stableSince >= .milliseconds(400),
               ObservationState.verify(decision, before: before.elements, after: latest.elements).verified { break }
        } while clock.now < deadline
        return latest
    }

    private func describe(_ decision: AgentDecision, elements: [AccessibilityElement]) -> String {
        let label = elements.first { String($0.id) == decision.targetIndex }?.displayLabel ?? "none"
        return "\(decision.operation) target=\(label) text=\(decision.textValue ?? "") key=\(decision.key ?? "")"
    }

    // MARK: - Execution

    private func execute(_ decision: AgentDecision, elements: [AccessibilityElement], windowFrame: CGRect?) async throws {
        let element = elements.first { String($0.id) == decision.targetIndex }
        let point: CGPoint?
        if let element, let frame = element.screenFrame() {
            point = CGPoint(x: frame.midX, y: frame.midY)
        } else { point = nil }
        func click(count: Int = 1, right: Bool = false) throws {
            guard let point else {
                Log.info("Click rejected reason=missing_target_bounds")
                throw ControllerError.invalid("The selected control did not expose a clickable position.")
            }
            guard let windowFrame, windowFrame.contains(point) else {
                Log.info("Click rejected reason=target_outside_window")
                throw ControllerError.invalid("Target is outside the current window")
            }
            try InputController.click(point, count: count, right: right)
        }
        try checkFocus()
        switch decision.operation {
        case "CLICK", "CLICK_TEXT":
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
            guard let element else { throw ControllerError.invalid("No editable field was selected.") }
            func fieldHasFocus() async throws -> Bool {
                if let ax = element.axElement {
                    return TextFieldFocus.confirmed(ax, app: self.target.appElement)
                }
                let fresh = try await self.observe()
                return ObservationState.matching(element, in: fresh.elements)?.focused == true
            }
            phase = "confirming_field_focus"
            Log.info("Text entry stage=confirming_focus")
            try await TextFieldFocus.prepare(check: checkFocus, probe: fieldHasFocus, requestFocus: {
                if let ax = element.axElement {
                    AXUIElementSetAttributeValue(ax, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                }
            }, click: {
                Log.info("Text entry stage=clicking_field")
                try click()
            })
            try checkFocus()
            if TextEntryPlan.isTerminal(target.bundleIdentifier) {
                // Readline-style editing for a shell prompt; Command-A selects scrollback.
                try InputController.press("a", modifiers: ["control"])
                try InputController.press("k", modifiers: ["control"])
            } else { try InputController.press("a", modifiers: ["command"]) }
            try await Task.sleep(nanoseconds: 80_000_000)
            func checkTypingFocus() throws {
                try checkFocus()
                if let ax = element.axElement,
                   !TextFieldFocus.confirmed(ax, app: target.appElement) {
                    throw TextFieldFocus.Failure.changed
                }
            }
            try checkTypingFocus()
            phase = "typing_text"
            Log.info("Text entry stage=typing")
            try await InputController.type(text, check: checkTypingFocus)
            if TextEntryPlan.isTerminal(target.bundleIdentifier) { terminalEntrySent = true }
            Log.info("Text entry stage=input_sent")
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
