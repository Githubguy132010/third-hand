import ApplicationServices

enum AXTreeWalker {
    static func walk(target: AppTarget) -> [AccessibilityElement] {
        var elements: [AccessibilityElement] = []
        var nextId = 1
        let root = target.windowElement ?? target.appElement

        enumerate(root, depth: 0, maxDepth: 12, elements: &elements, nextId: &nextId, limit: 300)

        if elements.isEmpty {
            var winVal: AnyObject?
            AXUIElementCopyAttributeValue(target.appElement, kAXWindowsAttribute as CFString, &winVal)
            if let windows = winVal as? [AXUIElement] {
                for win in windows {
                    enumerate(win, depth: 0, maxDepth: 12, elements: &elements, nextId: &nextId, limit: 300)
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
        limit: Int
    ) {
        guard depth < maxDepth, elements.count < limit else { return }

        let role = attr(element, kAXRoleAttribute) as? String ?? ""
        let title = attr(element, kAXTitleAttribute) as? String
        let desc = attr(element, kAXDescriptionAttribute) as? String
        let roleDesc = attr(element, kAXRoleDescriptionAttribute) as? String
        let value = attr(element, kAXValueAttribute) as? String
        let enabled = (attr(element, kAXEnabledAttribute) as? Bool) ?? true
        let label = title ?? desc ?? roleDesc

        var actionNames: CFArray?
        AXUIElementCopyActionNames(element, &actionNames)
        let actions = (actionNames as? [String]) ?? []

        let hasAnyAction = !actions.isEmpty
        let hasLabel = (label != nil && label != "") || (value != nil && value != "")
        let shouldSkip = skipRoles.contains(role) || role == "AXGroup"

        if !shouldSkip && hasLabel && (hasAnyAction || isInteractiveRole(role)) {
            elements.append(AccessibilityElement(
                id: nextId,
                role: role,
                label: label,
                value: value,
                enabled: enabled,
                actions: actions,
                axElement: element
            ))
            nextId += 1
        }

        guard let children = attr(element, kAXChildrenAttribute) as? [AXUIElement] else { return }
        for child in children {
            enumerate(child, depth: depth + 1, maxDepth: maxDepth, elements: &elements, nextId: &nextId, limit: limit)
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
