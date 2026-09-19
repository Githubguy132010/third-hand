import AppKit
import ApplicationServices

@MainActor
enum InputController {
    nonisolated static let keyCodes: [String: CGKeyCode] = [
        "a":0,"s":1,"d":2,"f":3,"h":4,"g":5,"z":6,"x":7,"c":8,"v":9,"b":11,
        "q":12,"w":13,"e":14,"r":15,"y":16,"t":17,"1":18,"2":19,"3":20,"4":21,
        "6":22,"5":23,"9":25,"7":26,"8":28,"0":29,"o":31,"u":32,"i":34,"p":35,
        "l":37,"j":38,"k":40,"n":45,"m":46,"return":36,"tab":48,"space":49,"delete":51,
        "escape":53,"left":123,"right":124,"down":125,"up":126,
        "f1":122,"f2":120,"f3":99,"f4":118,"f5":96,"f6":97,"f7":98,"f8":100,
        "f9":101,"f10":109,"f11":103,"f12":111
    ]

    static func frame(_ element: AXUIElement) -> CGRect? {
        var pos: CFTypeRef?
        var size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &pos) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let pos, let size, CFGetTypeID(pos) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(pos as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &dimensions), dimensions.width > 0, dimensions.height > 0 else { return nil }
        return CGRect(origin: point, size: dimensions)
    }

    static func click(_ point: CGPoint, count: Int = 1, right: Bool = false) throws {
        for n in 1...count {
            guard let down = CGEvent(mouseEventSource: nil, mouseType: right ? .rightMouseDown : .leftMouseDown,
                                     mouseCursorPosition: point, mouseButton: right ? .right : .left),
                  let up = CGEvent(mouseEventSource: nil, mouseType: right ? .rightMouseUp : .leftMouseUp,
                                   mouseCursorPosition: point, mouseButton: right ? .right : .left) else { throw ControllerError.invalid("Cannot create mouse event") }
            down.setIntegerValueField(.mouseEventClickState, value: Int64(n))
            up.setIntegerValueField(.mouseEventClickState, value: Int64(n))
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }

    static func press(_ key: String, modifiers: [String] = []) throws {
        guard let code = keyCodes[key.lowercased()],
              let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) else { throw ControllerError.invalid("Unsupported key") }
        let flags = modifiers.reduce(CGEventFlags()) { flags, name in
            flags.union(["command": .maskCommand, "shift": .maskShift, "option": .maskAlternate, "control": .maskControl][name] ?? [])
        }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    static func type(_ text: String) throws {
        // Unicode events avoid changing or leaking the user's clipboard.
        for character in text {
            let units = Array(String(character).utf16)
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else { throw ControllerError.invalid("Cannot create text event") }
            units.withUnsafeBufferPointer { buffer in
                down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: buffer.baseAddress)
                up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: buffer.baseAddress)
            }
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }

    static func scroll(_ delta: Int32, at point: CGPoint) throws {
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0) else { throw ControllerError.invalid("Cannot create scroll event") }
        event.location = point
        event.post(tap: .cghidEventTap)
    }
}
