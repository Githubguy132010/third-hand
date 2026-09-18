import Foundation
import ApplicationServices

struct JevDecision {
    let operation: String
    let targetIndex: String?
    let textValue: String?
    let confidence: Double
}

enum JevError: LocalizedError {
    case apiError(Int, String)
    case parseError(String)
    case noAPIKey

    var errorDescription: String? {
        switch self {
        case .apiError(let c, let b): return "API \(c): \(b)"
        case .parseError(let c): return "Parse: \(c)"
        case .noAPIKey: return "No API key"
        }
    }
}

struct ActionHistory {
    let action: String
    let kind: String
    let text: String
    let pageChanged: Bool
}

private let NEXT_ACTION = """
    Advance the user's entire goal using one operation.
    Use current field values and action history. Do not repeat satisfied steps.
    Do not toggle a checkbox or switch already in the requested state.
    WAIT only when needed control is absent/disabled or results are still loading.
    DONE requires visible evidence that ALL requirements are satisfied.
    BLOCKED means no supported operation can make progress.
    """

private let TARGET = """
    Choose the best observed target for the specified operation.
    Use the user's goal, field values, and recent actions.
    Do not choose a field that already contains the requested value.
    Choose only an offered element index.
    """

final class JevClient {
    private let apiKey: String
    private let baseURL: String
    private let model: String
    private let session: URLSession

    init(apiKey: String, baseURL: String = "https://openrouter.ai/api/v1", model: String = "typesafe/jev-1.13") {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.model = model
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 25
        self.session = URLSession(configuration: config)
    }

    func decide(
        goal: String,
        elements: [AccessibilityElement],
        appName: String,
        history: [ActionHistory] = []
    ) async throws -> JevDecision {
        let (tsElements, targets) = buildActionSpace(elements)

        // Build the TypeSafe System One request body
        var operationCriteria: [String: String] = [:]
        if targets["CLICK"] != nil {
            operationCriteria["CLICK"] = "Click an element, button, menu option, or row."
        }
        if targets["TYPE_TEXT"] != nil {
            operationCriteria["TYPE_TEXT"] = "Enter or replace text in an editable field."
        }
        operationCriteria["SCROLL_UP"] = "Scroll the view up to reveal content above."
        operationCriteria["SCROLL_DOWN"] = "Scroll the view down to reveal content below."
        operationCriteria["DONE"] = "Every requirement is visibly satisfied."
        operationCriteria["BLOCKED"] = "No supported operation can progress."

        var questions: [String: Any] = [
            "operation": [
                "type": "choice",
                "criteria": operationCriteria,
                "instructions": ["goal": goal, "rules": NEXT_ACTION],
            ] as [String: Any],
        ]

        for (operation, opTargets) in targets {
            var criteria: [String: Any] = [:]
            for (index, elem) in opTargets {
                criteria[index] = [
                    "element": "[\(index)] \(elem.displayLabel)",
                    "role": elem.displayRole,
                    "current_value": elem.value ?? "",
                ] as [String: String]
            }
            questions[operation.lowercased() + "_target"] = [
                "type": "choice",
                "criteria": criteria,
                "instructions": ["goal": goal, "operation": operation, "rules": [NEXT_ACTION, TARGET]],
            ] as [String: Any]
        }

        if targets["TYPE_TEXT"] != nil {
            var textCriteria: [String: String] = [:]
            let candidates = generateTextCandidates(goal: goal)
            for (i, text) in candidates.enumerated() {
                textCriteria["t\(i)"] = text
            }
            questions["type_text_value"] = [
                "type": "choice",
                "criteria": textCriteria,
                "instructions": ["goal": goal, "rules": "Pick the text that should be typed into the field to advance the goal. Choose the most specific and relevant text."],
            ] as [String: Any]
        }

        let recentActions: [[String: Any]] = history.suffix(10).map { h in
            ["action": h.action, "kind": h.kind, "text": h.text, "page_changed": h.pageChanged]
        }

        let body: [String: Any] = [
            "model": model,
            "state": [
                "page": ["url": "", "title": appName, "text": ""],
                "elements": tsElements,
                "recent_actions": recentActions,
            ] as [String: Any],
            "questions": questions,
        ]

        var req = URLRequest(url: URL(string: "https://openrouter.ai/api/alpha/decisions")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        Log.info("Jev request: \(tsElements.count) elements, \(targets.count) op types, questions: \(Array(questions.keys))")
        if let bodyStr = String(data: req.httpBody ?? Data(), encoding: .utf8) {
            Log.info("Jev body (first 800): \(String(bodyStr.prefix(800)))")
        }

        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let responseBody = String(data: data, encoding: .utf8) ?? ""

        Log.info("Jev response \(code): \(String(responseBody.prefix(600)))")

        if code != 200 {
            throw JevError.apiError(code, responseBody)
        }

        let textCandidates = targets["TYPE_TEXT"] != nil ? generateTextCandidates(goal: goal) : []
        return try parseResponse(data: data, targets: targets, textCandidates: textCandidates)
    }

    private func buildActionSpace(_ elements: [AccessibilityElement]) -> ([[String: Any]], [String: [String: AccessibilityElement]]) {
        var tsElements: [[String: Any]] = []
        var clickTargets: [String: AccessibilityElement] = [:]
        var typeTargets: [String: AccessibilityElement] = [:]

        let clickActions: Set<String> = [
            kAXPressAction as String,
            "AXOpen",
            "AXConfirm",
            "AXPick",
        ]

        for elem in elements {
            let index = String(elem.id)
            var operations: [String] = []
            let canClick = !elem.actions.filter({ clickActions.contains($0) }).isEmpty || isClickableRole(elem.role)
            let isTextField = elem.role == "AXTextField" || elem.role == "AXTextArea" || elem.role == "AXComboBox"

            if canClick { operations.append("CLICK"); clickTargets[index] = elem }
            if isTextField {
                if !canClick { operations.append("CLICK"); clickTargets[index] = elem }
                operations.append("TYPE_TEXT"); typeTargets[index] = elem
            }
            guard !operations.isEmpty else { continue }

            var d: [String: Any] = ["index": index, "label": elem.displayLabel, "role": elem.displayRole, "operations": operations]
            if let v = elem.value, !v.isEmpty { d["value"] = v }
            tsElements.append(d)
        }

        var targets: [String: [String: AccessibilityElement]] = [:]
        if !clickTargets.isEmpty { targets["CLICK"] = clickTargets }
        if !typeTargets.isEmpty { targets["TYPE_TEXT"] = typeTargets }
        return (tsElements, targets)
    }

    private func generateTextCandidates(goal: String) -> [String] {
        var candidates: [String] = [goal]
        let words = goal.split(separator: " ").map(String.init)
        // Add individual meaningful words (skip short/common ones)
        let stopWords: Set<String> = ["go", "to", "the", "a", "an", "and", "or", "in", "on", "for", "of", "open", "find", "search", "click", "navigate", "type", "enter", "play", "start", "set", "change", "my", "its", "is", "it"]
        let meaningful = words.filter { $0.count > 1 && !stopWords.contains($0.lowercased()) }
        for w in meaningful { candidates.append(w) }
        // Add consecutive pairs
        if meaningful.count >= 2 {
            for i in 0..<(meaningful.count - 1) {
                candidates.append("\(meaningful[i]) \(meaningful[i+1])")
            }
        }
        // Add all meaningful words joined
        if meaningful.count >= 2 {
            candidates.append(meaningful.joined(separator: " "))
        }
        // Deduplicate preserving order
        var seen = Set<String>()
        return candidates.filter { seen.insert($0.lowercased()).inserted }.prefix(15).map { $0 }
    }

    private func isClickableRole(_ role: String) -> Bool {
        switch role {
        case "AXButton", "AXMenuItem", "AXMenuBarItem", "AXLink",
             "AXTab", "AXCheckBox", "AXRadioButton", "AXPopUpButton",
             "AXRow", "AXOutlineRow", "AXTableRow", "AXCell",
             "AXDisclosureTriangle", "AXToolbarButton", "AXMenuButton",
             "AXSwitch", "AXStaticText":
            return true
        default:
            return false
        }
    }

    private func parseResponse(data: Data, targets: [String: [String: AccessibilityElement]], textCandidates: [String]) throws -> JevDecision {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw JevError.parseError(String(data: data, encoding: .utf8) ?? "")
        }

        // Direct TypeSafe format: {answers: {operation: {choice, confidence, probabilities}}}
        if let answers = json["answers"] as? [String: Any],
           let opAnswer = answers["operation"] as? [String: Any],
           let operation = opAnswer["choice"] as? String,
           let confidence = opAnswer["confidence"] as? Double {
            var targetIndex: String? = nil
            if targets[operation] != nil {
                let key = operation.lowercased() + "_target"
                if let ta = answers[key] as? [String: Any], let c = ta["choice"] as? String {
                    targetIndex = c
                }
            }
            var textValue: String? = nil
            if operation == "TYPE_TEXT",
               let tv = answers["type_text_value"] as? [String: Any],
               let choiceKey = tv["choice"] as? String,
               let idx = Int(choiceKey.dropFirst()),
               idx < textCandidates.count {
                textValue = textCandidates[idx]
            }
            return JevDecision(operation: operation, targetIndex: targetIndex, textValue: textValue, confidence: confidence)
        }

        // OpenRouter chat wrapper: {choices: [{message: {content: "..."}}]}
        if let choices = json["choices"] as? [[String: Any]],
           let msg = choices.first?["message"] as? [String: Any],
           let content = msg["content"] as? String {
            let cleaned = content
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let d = cleaned.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
               let op = obj["operation"] as? String {
                let target = obj["target"] as? Int
                return JevDecision(operation: op, targetIndex: target.map(String.init), textValue: nil, confidence: 1.0)
            }
        }

        throw JevError.parseError(String(data: data, encoding: .utf8) ?? "")
    }
}
