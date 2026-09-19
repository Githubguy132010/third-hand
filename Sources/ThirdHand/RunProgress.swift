import Foundation
import ApplicationServices

struct ActionVerification {
    let verified: Bool
    let detail: String
}

enum ObservationState {
    /// Snapshot-local IDs and traversal order are not identities.
    static func signature(_ elements: [AccessibilityElement]) -> String {
        elements.map { element in
            let box = element.frame.map { "\(Int(($0.midX / 8).rounded())),\(Int(($0.midY / 8).rounded()))" } ?? ""
            return "\(element.source)|\(element.role)|\(element.displayLabel)|\(element.value ?? "")|\(element.enabled)|\(element.focused)|\(box)"
        }.sorted().joined(separator: "\n")
    }

    static func matching(_ target: AccessibilityElement, in elements: [AccessibilityElement]) -> AccessibilityElement? {
        if let ax = target.axElement, let exact = elements.first(where: { $0.axElement.map { CFEqual(ax, $0) } ?? false }) { return exact }
        let matches = elements.filter { $0.source == target.source && $0.role == target.role && $0.displayLabel == target.displayLabel }
        if matches.count == 1 { return matches[0] }
        if let frame = target.frame {
            return matches.first { candidate in
                guard let other = candidate.frame else { return false }
                return abs(frame.midX - other.midX) < 8 && abs(frame.midY - other.midY) < 8
            }
        }
        return nil
    }

    static func verify(_ decision: AgentDecision, before: [AccessibilityElement], after: [AccessibilityElement]) -> ActionVerification {
        let target = before.first { String($0.id) == decision.targetIndex }
        if decision.operation == "TYPE_TEXT" {
            guard let target, let actual = matching(target, in: after), actual.value == decision.textValue else {
                return ActionVerification(verified: false, detail: "Text entry could not be verified in the selected field. Do not assume it succeeded.")
            }
            return ActionVerification(verified: true, detail: "Selected field contains the complete requested text. Submission is not yet verified.")
        }
        if let target, let actual = matching(target, in: after), !target.focused && actual.focused {
            return ActionVerification(verified: true, detail: "The selected control gained focus; the overall goal still needs checking.")
        }
        let changed = signature(before) != signature(after)
        return ActionVerification(verified: changed, detail: changed
            ? "Observed UI state changed after input. Check the current screen for the intended result; change alone is not completion."
            : "No observable effect after waiting for the UI to settle. Do not repeat the same action without a different strategy.")
    }
}

struct RunProgress {
    private var pairs: [String] = []
    private var actions: [String] = []
    private(set) var failures = 0
    private(set) var usedRecovery = false

    mutating func record(_ verification: ActionVerification) { failures = verification.verified ? 0 : failures + 1 }

    mutating func problem(decision: AgentDecision, elements: [AccessibilityElement]) -> String? {
        let target = elements.first { String($0.id) == decision.targetIndex }
        let identity = target.map { "\($0.role):\($0.displayLabel):\($0.frame.map { "\(Int($0.midX / 8)),\(Int($0.midY / 8))" } ?? "")" } ?? "\(decision.x ?? -1),\(decision.y ?? -1)"
        let action = "\(decision.operation)|\(identity)|\(decision.textValue ?? "")|\(decision.key ?? "")|\((decision.modifiers ?? []).sorted())"
        let pair = action + "\n" + ObservationState.signature(elements)
        pairs.append(pair)
        actions.append(action)
        pairs = Array(pairs.suffix(12))
        actions = Array(actions.suffix(12))
        if failures >= 2 { return "The last two actions had no verified effect." }
        if pairs.filter({ $0 == pair }).count >= 3 { return "The task is cycling through the same actions and screens." }
        if !["SCROLL_UP", "SCROLL_DOWN", "WAIT"].contains(decision.operation), actions.filter({ $0 == action }).count >= 4 {
            return "The same action keeps recurring without reaching the goal."
        }
        return nil
    }

    mutating func beginRecovery() -> Bool {
        guard !usedRecovery else { return false }
        usedRecovery = true
        failures = 0
        pairs.removeAll()
        actions.removeAll()
        return true
    }
}
