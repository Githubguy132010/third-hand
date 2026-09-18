import AppKit
import ApplicationServices

protocol TaskRunnerDelegate: AnyObject {
    func taskRunner(_ r: TaskRunner, status: String)
    func taskRunnerDone(_ r: TaskRunner)
    func taskRunnerFailed(_ r: TaskRunner, error: String)
    func taskRunnerNeedsInput(_ r: TaskRunner, prompt: String, completion: @escaping (String?) -> Void)
}

final class TaskRunner {
    let target: AppTarget
    let goal: String
    let client: JevClient
    weak var delegate: TaskRunnerDelegate?

    private var cancelled = false
    private var history: [ActionHistory] = []
    private var elementMap: [String: AccessibilityElement] = [:]
    private let maxSteps = 25

    init(target: AppTarget, goal: String, client: JevClient) {
        self.target = target
        self.goal = goal
        self.client = client
    }

    func start() {
        cancelled = false
        Task { @MainActor in await run() }
    }

    func cancel() { cancelled = true }

    @MainActor
    private func run() async {
        Log.info("TaskRunner: goal=\"\(goal)\" app=\(target.name)")
        target.application.activate()
        try? await Task.sleep(nanoseconds: 400_000_000)

        for _ in 0..<maxSteps {
            guard !cancelled else {
                delegate?.taskRunner(self, status: "Cancelled")
                return
            }

            delegate?.taskRunner(self, status: "Observing…")
            let elements = AXTreeWalker.walk(target: target)
            elementMap = [:]
            for e in elements { elementMap[String(e.id)] = e }

            if elements.isEmpty {
                delegate?.taskRunnerFailed(self, error: "\(target.name) doesn't expose its UI to Accessibility. Electron/Chromium apps like Spotify often don't. Try a native macOS app.")
                return
            }

            delegate?.taskRunner(self, status: "Thinking…")

            let decision: JevDecision
            do {
                decision = try await client.decide(
                    goal: goal,
                    elements: elements,
                    appName: target.name,
                    history: history
                )
            } catch {
                delegate?.taskRunnerFailed(self, error: error.localizedDescription)
                return
            }

            guard !cancelled else { return }

            NSLog("[ThirdHand] Decision: %@ target=%@ confidence=%.2f", decision.operation, decision.targetIndex ?? "nil", decision.confidence)

            switch decision.operation {
            case "DONE":
                delegate?.taskRunnerDone(self)
                return

            case "BLOCKED":
                delegate?.taskRunnerFailed(self, error: "Blocked — cannot proceed")
                return

            case "CLICK":
                guard let idx = decision.targetIndex, let el = elementMap[idx] else {
                    delegate?.taskRunnerFailed(self, error: "Invalid click target")
                    return
                }
                delegate?.taskRunner(self, status: "Clicking \"\(el.displayLabel)\"…")
                performClick(el)
                history.append(ActionHistory(action: "CLICK [\(idx)] \(el.displayLabel)", kind: "click", text: "", pageChanged: true))

            case "TYPE_TEXT":
                guard let idx = decision.targetIndex, let el = elementMap[idx] else {
                    delegate?.taskRunnerFailed(self, error: "Invalid type target")
                    return
                }
                var text = decision.textValue
                if text == nil {
                    text = await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in
                        delegate?.taskRunnerNeedsInput(self, prompt: el.displayLabel) { c.resume(returning: $0) }
                    }
                }
                guard let text else { cancel(); return }

                delegate?.taskRunner(self, status: "Typing \"\(text)\" in \"\(el.displayLabel)\"…")
                AXUIElementPerformAction(el.axElement, kAXPressAction as CFString)
                try? await Task.sleep(nanoseconds: 150_000_000)
                AXUIElementSetAttributeValue(el.axElement, kAXValueAttribute as CFString, text as CFTypeRef)
                history.append(ActionHistory(action: "TYPE_TEXT [\(idx)] \(el.displayLabel)", kind: "fill", text: text, pageChanged: false))

            case "SCROLL_UP":
                delegate?.taskRunner(self, status: "Scrolling up…")
                postScroll(5)
                history.append(ActionHistory(action: "SCROLL_UP", kind: "scroll", text: "", pageChanged: false))

            case "SCROLL_DOWN":
                delegate?.taskRunner(self, status: "Scrolling down…")
                postScroll(-5)
                history.append(ActionHistory(action: "SCROLL_DOWN", kind: "scroll", text: "", pageChanged: false))

            case "WAIT":
                delegate?.taskRunner(self, status: "Waiting…")
                history.append(ActionHistory(action: "WAIT", kind: "wait", text: "", pageChanged: false))

            default:
                delegate?.taskRunnerFailed(self, error: "Unknown operation: \(decision.operation)")
                return
            }

            try? await Task.sleep(nanoseconds: 600_000_000)
        }

        delegate?.taskRunnerFailed(self, error: "Reached step limit")
    }

    private func performClick(_ el: AccessibilityElement) {
        let preferred = ["AXPress", "AXOpen", "AXConfirm", "AXPick"]
        for action in preferred {
            if el.actions.contains(action) {
                AXUIElementPerformAction(el.axElement, action as CFString)
                return
            }
        }
        if let first = el.actions.first {
            AXUIElementPerformAction(el.axElement, first as CFString)
        }
    }

    private func postScroll(_ delta: Int32) {
        guard let frame = target.windowFrame else { return }
        let screenH = NSScreen.screens.first?.frame.height ?? 0
        let pt = CGPoint(x: frame.midX, y: screenH - frame.midY)
        if let ev = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0) {
            ev.location = pt
            ev.post(tap: .cghidEventTap)
        }
    }
}
