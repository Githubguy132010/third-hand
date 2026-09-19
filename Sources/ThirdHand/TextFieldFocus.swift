import ApplicationServices
import Foundation

/// Query the app's focused element directly: tree snapshots may omit AXFocused,
/// and composite fields can give keyboard focus to an inner editor.
@MainActor
enum TextFieldFocus {
    enum Failure: String, LocalizedError {
        case unavailable = "field_focus_unconfirmed"
        case changed = "field_focus_changed"
        var errorDescription: String? {
            switch self {
            case .unavailable: return "The selected text field did not report keyboard focus after waiting. No text was entered."
            case .changed: return "Keyboard focus left the selected text field. Text entry was stopped."
            }
        }
    }

    static func contains<Node>(_ focused: Node, target: Node,
                               equal: (Node, Node) -> Bool, parent: (Node) -> Node?) -> Bool {
        var current: Node? = focused
        // Bound broken or cyclic accessibility parent chains.
        for _ in 0..<32 {
            guard let node = current else { return false }
            if equal(node, target) { return true }
            current = parent(node)
        }
        return false
    }

    private static func elementAttribute(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func confirmed(_ field: AXUIElement, app: AXUIElement) -> Bool {
        if let focused = elementAttribute(app, kAXFocusedUIElementAttribute) {
            // An explicit different focused control takes precedence over a stale flag.
            return contains(focused, target: field, equal: { CFEqual($0, $1) },
                            parent: { elementAttribute($0, kAXParentAttribute) })
        }
        var flag: CFTypeRef?
        return AXUIElementCopyAttributeValue(field, kAXFocusedAttribute as CFString, &flag) == .success
            && (flag as? Bool) == true
    }

    /// A focused field needs no geometry or second click. Request AX focus before
    /// falling back to a mouse click, since some editable controls have no bounds.
    static func prepare(attempts: Int = 11, interval: UInt64 = 100_000_000,
                        check: () throws -> Void, probe: () async throws -> Bool,
                        requestFocus: () throws -> Void, click: () throws -> Void) async throws {
        try Task.checkCancellation()
        try check()
        let alreadyFocused = try await probe()
        try Task.checkCancellation()
        try check()
        if alreadyFocused { return }
        try requestFocus()
        do {
            try await wait(attempts: attempts, interval: interval, check: check, probe: probe)
            return
        } catch Failure.unavailable {
            // Only a focus timeout warrants a click; cancellation/app changes propagate.
        }
        try check()
        try click()
        try await wait(attempts: attempts, interval: interval, check: check, probe: probe)
    }

    static func wait(attempts: Int = 11, interval: UInt64 = 100_000_000,
                     check: () throws -> Void, probe: () async throws -> Bool) async throws {
        for attempt in 0..<attempts {
            try Task.checkCancellation()
            try check()
            let focused = try await probe()
            try Task.checkCancellation()
            try check()
            if focused { return }
            if attempt + 1 < attempts { try await Task.sleep(nanoseconds: interval) }
        }
        throw Failure.unavailable
    }
}
