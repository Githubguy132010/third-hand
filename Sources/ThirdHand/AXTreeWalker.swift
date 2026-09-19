import ApplicationServices
import Foundation

enum AXTreeWalker {
    static func walk(target: AppTarget, timeBudget: TimeInterval = 0.8) -> [AccessibilityElement] {
        var elements: [AccessibilityElement] = []
        var nextId = 1
        var visited = 0
        let deadline = Date().addingTimeInterval(timeBudget)
        AXUIElementSetMessagingTimeout(target.appElement, 0.1)
        var focused: CFTypeRef?
        AXUIElementCopyAttributeValue(target.appElement, kAXFocusedWindowAttribute as CFString, &focused)
        let root = focused.map { $0 as! AXUIElement } ?? target.appElement

        enumerate(root, depth: 0, maxDepth: 30, elements: &elements, nextId: &nextId, visited: &visited, deadline: deadline, limit: 500)

        if elements.isEmpty {
            var winVal: AnyObject?
            AXUIElementCopyAttributeValue(target.appElement, kAXWindowsAttribute as CFString, &winVal)
            if let windows = winVal as? [AXUIElement] {
                for win in windows {
                    enumerate(win, depth: 0, maxDepth: 30, elements: &elements, nextId: &nextId, visited: &visited, deadline: deadline, limit: 500)
                }
            }
        }

        Log.info("AXWalk: \(elements.count) elements for \(target.name)")
        return elements
    }

    private static let skipRoles: Set<String> = [
        "AXScrollArea", "AXSplitGroup", "AXLayoutArea",
        "AXScrollBar", "AXWindow", "AXSheet", "AXDrawer",
    ]

    private static func enumerate(
        _ element: AXUIElement,
        depth: Int,
        maxDepth: Int,
        elements: inout [AccessibilityElement],
        nextId: inout Int,
        visited: inout Int,
        deadline: Date,
        limit: Int
    ) {
        guard depth < maxDepth, elements.count < limit, visited < 3000, Date() < deadline else { return }
        visited += 1

        // Fetch metadata together instead of making a separate cross-process call per attribute.
        let keys = [kAXRoleAttribute, kAXTitleAttribute, kAXDescriptionAttribute,
                    kAXRoleDescriptionAttribute, kAXValueAttribute, kAXEnabledAttribute, kAXChildrenAttribute]
        var batch: CFArray?
        let result = AXUIElementCopyMultipleAttributeValues(element, keys as CFArray, [], &batch)
        let values = batch as? [AnyObject]
        func attribute(_ key: String) -> AnyObject? {
            if result == .success, let index = keys.firstIndex(of: key), let values, index < values.count {
                return values[index]
            }
            return attr(element, key)
        }
        let role = attribute(kAXRoleAttribute) as? String ?? ""
        let title = attribute(kAXTitleAttribute) as? String
        let desc = attribute(kAXDescriptionAttribute) as? String
        let roleDesc = attribute(kAXRoleDescriptionAttribute) as? String
        let rawValue = attribute(kAXValueAttribute)
        let value = (rawValue as? String) ?? (rawValue as? NSNumber)?.stringValue
        let enabled = (attribute(kAXEnabledAttribute) as? Bool) ?? true
        let label = [title, desc, roleDesc].compactMap { $0 }.first { !$0.isEmpty }

        var actionNames: CFArray?
        AXUIElementCopyActionNames(element, &actionNames)
        let actions = (actionNames as? [String]) ?? []

        let hasAnyAction = !actions.isEmpty
        let hasLabel = (label != nil && label != "") || (value != nil && value != "")
        let shouldSkip = skipRoles.contains(role) || (role == "AXGroup" && !hasAnyAction)

        if !shouldSkip && hasLabel && (hasAnyAction || isInteractiveRole(role) || role == "AXStaticText") {
            elements.append(AccessibilityElement(
                id: nextId,
                role: role,
                label: label,
                value: value,
                enabled: enabled,
                actions: actions,
                axElement: element,
                frame: nil
            ))
            nextId += 1
        }

        guard let children = attribute(kAXChildrenAttribute) as? [AXUIElement] else { return }
        for child in children {
            enumerate(child, depth: depth + 1, maxDepth: maxDepth, elements: &elements, nextId: &nextId, visited: &visited, deadline: deadline, limit: limit)
        }
    }

    private static func isInteractiveRole(_ role: String) -> Bool {
        switch role {
        case "AXButton", "AXTextField", "AXTextArea", "AXCheckBox",
             "AXRadioButton", "AXPopUpButton", "AXMenuItem", "AXMenuBarItem",
             "AXRow", "AXCell", "AXLink", "AXTab", "AXSlider",
             "AXComboBox", "AXDisclosureTriangle", "AXIncrementor",
             "AXOutlineRow", "AXTableRow", "AXOutline",
             "AXToolbarButton", "AXMenuButton", "AXSwitch",
             "AXWebArea", "AXList", "AXTable":
            return true
        default:
            return false
        }
    }

    private static func attr(_ el: AXUIElement, _ key: String) -> AnyObject? {
        var val: AnyObject?
        AXUIElementCopyAttributeValue(el, key as CFString, &val)
        return val
    }
}
