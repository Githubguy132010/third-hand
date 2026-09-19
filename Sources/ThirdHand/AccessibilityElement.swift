import ApplicationServices

struct AccessibilityElement {
    let id: Int
    let role: String
    let label: String?
    let value: String?
    let enabled: Bool
    let actions: [String]
    let axElement: AXUIElement?
    let frame: CGRect?

    var displayRole: String {
        let clean = role.replacingOccurrences(of: "AX", with: "")
        return clean.prefix(1).lowercased() + clean.dropFirst()
    }

    var displayLabel: String {
        label ?? value ?? "(unlabeled)"
    }

    func compactDescription() -> String {
        var parts = "[\(id)] \(displayRole) \"\(displayLabel)\""
        if let v = value, v != label, !v.isEmpty {
            parts += " · \(v)"
        }
        return parts
    }

    func screenFrame() -> CGRect? {
        if let frame { return frame }
        guard let ax = axElement else { return nil }
        var pos: CFTypeRef?
        var size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ax, kAXPositionAttribute as CFString, &pos) == .success,
              AXUIElementCopyAttributeValue(ax, kAXSizeAttribute as CFString, &size) == .success,
              let pos, let size,
              CFGetTypeID(pos) == AXValueGetTypeID(),
              CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(pos as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &dimensions),
              dimensions.width > 0, dimensions.height > 0 else { return nil }
        return CGRect(origin: point, size: dimensions)
    }
}
