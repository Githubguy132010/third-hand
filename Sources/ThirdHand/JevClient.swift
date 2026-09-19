import Foundation

struct JevResult {
    let decision: AgentDecision
    let done: Double
    let absent: Double
    let pickedNone: Bool
    let latencyMs: Int
}

final class JevClient {
    private let apiKey: String
    private let session: URLSession
    private let endpoint: URL

    static let doneThreshold = 0.70
    static let absentThreshold = 0.50
    private static let noneKey = "__none__"

    init(apiKey: String, session: URLSession = .shared,
         endpoint: URL = URL(string: "https://api.typesafe.ai/v1/systemone")!) {
        self.apiKey = apiKey
        self.session = session
        self.endpoint = endpoint
    }

    static func targets(_ elements: [AccessibilityElement]) -> [String: [String: AccessibilityElement]] {
        var click: [String: AccessibilityElement] = [:]
        var type: [String: AccessibilityElement] = [:]
        let clickRoles: Set<String> = [
            "AXButton", "AXMenuItem", "AXMenuBarItem", "AXLink", "AXTab",
            "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXRow", "AXCell",
            "AXDisclosureTriangle", "AXSwitch"
        ]
        for element in elements where element.enabled {
            let id = String(element.id)
            if ["AXTextField", "AXTextArea", "AXComboBox"].contains(element.role) {
                type[id] = element
                click[id] = element
            } else if clickRoles.contains(element.role) ||
                      element.actions.contains(where: { ["AXPress", "AXOpen", "AXConfirm", "AXPick"].contains($0) }) {
                click[id] = element
            }
        }
        var result: [String: [String: AccessibilityElement]] = [:]
        if !click.isEmpty { result["CLICK"] = click }
        if !type.isEmpty { result["TYPE_TEXT"] = type }
        return result
    }

    static func requestBody(goal: String, elements: [AccessibilityElement], appName: String, history: [ActionHistory]) -> [String: Any] {
        let targets = targets(elements)

        var operations: [String: String] = [
            "SCROLL_UP": "Reveal content above",
            "SCROLL_DOWN": "Reveal content below",
            "PRESS_RETURN": "Submit the focused field or confirm the selected item",
            "PRESS_ESCAPE": "Dismiss the current popup or menu",
            "WAIT": "Wait for content to load",
            "DONE": "All requirements are visibly satisfied on screen",
            "BLOCKED": "No available operation can make progress"
        ]
        for op in targets.keys {
            operations[op] = op == "TYPE_TEXT"
                ? "Set text in an editable field"
                : "Click an observed enabled control"
        }

        let state: [String: Any] = [
            "task": goal,
            "app": appName,
            "step": history.count + 1,
            "already_done": history.isEmpty
                ? ["nothing yet"] as [Any]
                : history.suffix(8).map { "\($0.action): \($0.result)" } as [Any],
            "elements": elements.map { el in
                var desc: [String: Any] = ["id": String(el.id), "label": el.displayLabel, "role": el.displayRole]
                if let v = el.value, !v.isEmpty, v != el.label { desc["value"] = v }
                return desc
            }
        ]

        var questions: [String: Any] = [
            "done": [
                "type": "noul",
                "instructions": "Has this task been completed: \"\(goal)\"? Judge only by what is visible on screen and actions already taken."
            ] as [String: Any],
            "absent": [
                "type": "noul",
                "instructions": "Is the control needed for the next step of \"\(goal)\" missing from the elements on screen?"
            ] as [String: Any],
            "operation": [
                "type": "choice",
                "criteria": operations,
                "instructions": "Which operation advances \"\(goal)\" one step? Do not repeat completed steps. DONE requires visible evidence."
            ] as [String: Any]
        ]

        for (op, candidates) in targets {
            var criteria: [String: String] = [:]
            for (id, el) in candidates {
                var desc = el.displayLabel
                if let v = el.value, !v.isEmpty, v != el.label { desc += " = \(v)" }
                desc += " [\(el.displayRole)]"
                criteria[id] = desc
            }
            criteria[noneKey] = "None of these — the needed control is not on screen"
            questions[op.lowercased() + "_target"] = [
                "type": "choice",
                "criteria": criteria,
                "instructions": "Which element should be the target for \(op) to advance \"\(goal)\"?"
            ] as [String: Any]
        }

        return ["model": "jev-latest", "questions": questions, "state": state]
    }

    func decide(goal: String, elements: [AccessibilityElement], appName: String, history: [ActionHistory]) async throws -> JevResult {
        var request = URLRequest(url: endpoint, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = Self.requestBody(goal: goal, elements: elements, appName: appName, history: history)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let start = Date()
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        Log.info("Timing jev_ms=\(ms)")
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = String(data: data, encoding: .utf8) ?? ""
            Log.info("Jev error \(code): \(body.prefix(200))")
            throw ControllerError.invalid("Jev unavailable (HTTP \(code))")
        }
        return try Self.decode(data, elements: elements, latencyMs: ms)
    }

    // MARK: - Word-by-word text builder

    func buildText(goal: String, fieldLabel: String) async throws -> String {
        let endToken = "__end__"
        var wordPool = Set<String>()
        for word in goal.components(separatedBy: .whitespaces) where !word.isEmpty {
            wordPool.insert(word)
            let stripped = word.trimmingCharacters(in: .punctuationCharacters)
            if !stripped.isEmpty { wordPool.insert(stripped) }
        }
        for w in ["the", "a", "an", "my", "new", "best", "top", "all",
                   "1", "2", "3", "4", "5", "0", "-", ".", "@"] {
            wordPool.insert(w)
        }

        var criteria: [String: String] = [:]
        for word in wordPool { criteria[word] = word }
        criteria[endToken] = "Text is complete — stop here"

        var accumulated: [String] = []

        for _ in 0..<15 {
            let state: [String: Any] = [
                "task": goal,
                "field": fieldLabel,
                "typed": accumulated.isEmpty ? "(nothing yet)" : accumulated.joined(separator: " ")
            ]
            let questions: [String: Any] = [
                "next": [
                    "type": "choice",
                    "criteria": criteria,
                    "instructions": "Building text to type into \"\(fieldLabel)\" for: \"\(goal)\". Pick the next content word. Skip action verbs and app names. Pick \(endToken) when done."
                ] as [String: Any]
            ]
            let body: [String: Any] = ["model": "jev-latest", "questions": questions, "state": state]

            var req = URLRequest(url: endpoint, timeoutInterval: 10)
            req.httpMethod = "POST"
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (data, response) = try await session.data(for: req)
            try Task.checkCancellation()
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let answers = json["answers"] as? [String: Any],
                  let answer = answers["next"] as? [String: Any],
                  let choice = answer["choice"] as? String else {
                break
            }
            if choice == endToken { break }
            guard criteria[choice] != nil else { break }
            accumulated.append(choice)
        }

        guard !accumulated.isEmpty else {
            throw ControllerError.invalid("Could not determine what text to enter from your request")
        }
        Log.info("buildText: \"\(accumulated.joined(separator: " "))\" from goal: \"\(goal)\"")
        return accumulated.joined(separator: " ")
    }

    // MARK: - Decode

    static func decode(_ data: Data, elements: [AccessibilityElement], latencyMs: Int = 0) throws -> JevResult {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answers = json["answers"] as? [String: Any] else {
            throw ControllerError.invalid("Invalid Jev response")
        }

        let done = (answers["done"] as? [String: Any])?["noul"] as? Double ?? 0
        let absent = (answers["absent"] as? [String: Any])?["noul"] as? Double ?? 0

        guard let opAnswer = answers["operation"] as? [String: Any],
              let opChoice = opAnswer["choice"] as? String else {
            throw ControllerError.invalid("Missing operation in Jev response")
        }

        let targets = targets(elements)

        if let candidates = targets[opChoice] {
            let key = opChoice.lowercased() + "_target"
            guard let tgtAnswer = answers[key] as? [String: Any],
                  let tgtChoice = tgtAnswer["choice"] as? String else {
                throw ControllerError.invalid("Missing target for \(opChoice)")
            }
            if tgtChoice == noneKey {
                return JevResult(
                    decision: AgentDecision(operation: "BLOCKED", reason: "Target not visible on screen"),
                    done: done, absent: absent, pickedNone: true, latencyMs: latencyMs
                )
            }
            guard candidates[tgtChoice] != nil else {
                throw ControllerError.invalid("Invalid target \(tgtChoice)")
            }
            return JevResult(
                decision: AgentDecision(operation: opChoice, targetIndex: tgtChoice),
                done: done, absent: absent, pickedNone: false, latencyMs: latencyMs
            )
        }

        if opChoice == "PRESS_RETURN" || opChoice == "PRESS_ESCAPE" {
            return JevResult(
                decision: AgentDecision(operation: "KEY_PRESS", key: opChoice == "PRESS_RETURN" ? "return" : "escape"),
                done: done, absent: absent, pickedNone: false, latencyMs: latencyMs
            )
        }

        return JevResult(
            decision: AgentDecision(operation: opChoice),
            done: done, absent: absent, pickedNone: false, latencyMs: latencyMs
        )
    }
}
