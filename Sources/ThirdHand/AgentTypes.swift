import Foundation

struct AgentDecision: Codable, Equatable {
    let operation: String
    var targetIndex: String? = nil
    var textValue: String? = nil
    var x: Double? = nil
    var y: Double? = nil
    var key: String? = nil
    var modifiers: [String]? = nil
    var reason: String? = nil

    func validate(elements: [AccessibilityElement], hasScreenshot: Bool) throws {
        let operations = ["CLICK", "DOUBLE_CLICK", "RIGHT_CLICK", "TYPE_TEXT", "KEY_PRESS", "SCROLL_UP", "SCROLL_DOWN", "WAIT", "DONE", "BLOCKED"]
        guard operations.contains(operation) else { throw ControllerError.invalid("Unknown operation") }
        if let targetIndex {
            guard elements.contains(where: { String($0.id) == targetIndex && $0.enabled }) else {
                throw ControllerError.invalid("Invalid or disabled target")
            }
        }
        if x != nil || y != nil {
            guard hasScreenshot, let x, let y, x.isFinite, y.isFinite,
                  (0...1).contains(x), (0...1).contains(y) else {
                throw ControllerError.invalid("Invalid screenshot coordinates")
            }
        }
        if ["CLICK", "DOUBLE_CLICK", "RIGHT_CLICK", "TYPE_TEXT"].contains(operation) {
            guard targetIndex != nil || (x != nil && y != nil) else { throw ControllerError.invalid("Missing action target") }
        }
        if operation == "TYPE_TEXT" {
            if let targetIndex, let target = elements.first(where: { String($0.id) == targetIndex }) {
                guard ["AXTextField", "AXTextArea", "AXComboBox"].contains(target.role) else {
                    throw ControllerError.invalid("Text action requires an editable field")
                }
            }
            guard let textValue, textValue.utf16.count <= 12000 else { throw ControllerError.invalid("Missing or oversized text") }
        }
        if operation == "KEY_PRESS" {
            guard let key, InputController.keyCodes[key.lowercased()] != nil,
                  (modifiers ?? []).allSatisfy({ ["command", "shift", "option", "control"].contains($0) }) else {
                throw ControllerError.invalid("Unsupported keyboard shortcut")
            }
        }
    }
}

enum ControllerError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}

struct ActionHistory: Codable {
    let action: String
    let result: String
}
