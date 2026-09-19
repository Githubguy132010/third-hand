import Foundation

@MainActor
final class CDPClient {
    private let port: Int
    private var webSocket: URLSessionWebSocketTask?
    private var nextId = 1
    private let session: URLSession
    private var expectedFrame: CGRect?

    init(port: Int, session: URLSession = .shared) {
        self.port = port
        self.session = session
    }

    func connect(windowFrame: CGRect) async throws {
        struct Target: Decodable {
            let id: String
            let type: String
            let title: String
            let webSocketDebuggerUrl: String?
        }
        let url = URL(string: "http://localhost:\(port)/json")!
        let (data, _) = try await AsyncTimeout.run(seconds: 3, message: "Browser discovery timed out.") { [session] in
            try await session.data(for: URLRequest(url: url, timeoutInterval: 3))
        }
        let targets = try JSONDecoder().decode([Target].self, from: data)
        let pages = targets.filter { $0.type == "page" }
        guard pages.count == 1, let page = pages.first,
              let wsUrlString = page.webSocketDebuggerUrl,
              let wsUrl = URL(string: wsUrlString), wsUrl.scheme == "ws",
              ["localhost", "127.0.0.1", "[::1]"].contains(wsUrl.host ?? ""), wsUrl.port == port else {
            throw ControllerError.invalid("Browser target is missing or ambiguous; using accessibility.")
        }
        webSocket = session.webSocketTask(with: wsUrl)
        webSocket?.resume()
        _ = try await send(method: "Runtime.enable")
        expectedFrame = windowFrame
        _ = try await extractElements()
        Log.info("CDP connected to the verified focused page")
    }

    func disconnect() {
        webSocket?.cancel(with: .normalClosure, reason: nil)
        webSocket = nil
    }

    var isConnected: Bool { webSocket != nil }

    func extractElements() async throws -> [AccessibilityElement] {
        let result = try await send(method: "Runtime.evaluate", params: [
            "expression": Self.extractionJS,
            "returnByValue": true
        ])
        guard let inner = result["result"] as? [String: Any],
              let value = inner["value"] as? String,
              let data = value.data(using: .utf8) else {
            throw ControllerError.invalid("CDP DOM extraction returned no data")
        }
        let snapshot = try JSONDecoder().decode(DOMSnapshot.self, from: data)
        guard let expectedFrame, snapshot.screen.focused,
              abs(snapshot.screen.x - expectedFrame.minX) < 8,
              abs(snapshot.screen.y - expectedFrame.minY) < 8,
              abs(snapshot.screen.width - expectedFrame.width) < 8,
              abs(snapshot.screen.height - expectedFrame.height) < 8 else {
            throw ControllerError.invalid("Browser page does not match the focused app window")
        }
        let originX = snapshot.screen.x
        let originY = snapshot.screen.y
        return snapshot.elements.map { el in
            AccessibilityElement(
                id: el.id,
                role: el.role,
                label: el.label,
                value: el.value,
                enabled: el.enabled,
                actions: el.actions,
                axElement: nil,
                frame: CGRect(x: originX + el.rect.x,
                              y: originY + max(0, snapshot.screen.height - snapshot.viewportHeight) + el.rect.y,
                              width: el.rect.w,
                              height: el.rect.h),
                focused: el.focused
            )
        }
    }

    // MARK: - WebSocket transport

    private func send(method: String, params: [String: Any] = [:]) async throws -> [String: Any] {
        guard let ws = webSocket else { throw ControllerError.invalid("CDP not connected") }
        return try await AsyncTimeout.run(seconds: 10, message: "Browser request timed out.", onTimeout: { self.disconnect() }) {
            try await self.sendMessage(method: method, params: params, ws: ws)
        }
    }

    private func sendMessage(method: String, params: [String: Any], ws: URLSessionWebSocketTask) async throws -> [String: Any] {
        let id = nextId
        nextId += 1
        let message: [String: Any] = ["id": id, "method": method, "params": params]
        let data = try JSONSerialization.data(withJSONObject: message)
        try await ws.send(.data(data))
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            try Task.checkCancellation()
            let msg = try await ws.receive()
            let msgData: Data
            switch msg {
            case .data(let d): msgData = d
            case .string(let s): msgData = Data(s.utf8)
            @unknown default: continue
            }
            guard let json = try? JSONSerialization.jsonObject(with: msgData) as? [String: Any] else { continue }
            guard json["id"] as? Int == id else { continue }
            if let error = json["error"] as? [String: Any] {
                throw ControllerError.invalid("CDP: \(error["message"] as? String ?? "unknown error")")
            }
            return json["result"] as? [String: Any] ?? [:]
        }
        throw ControllerError.invalid("CDP request timed out")
    }

    // MARK: - Decodable types

    private struct DOMSnapshot: Decodable {
        struct Element: Decodable {
            let id: Int
            let role: String
            let label: String?
            let value: String?
            let enabled: Bool
            let focused: Bool
            let actions: [String]
            let rect: Rect
        }
        struct Rect: Decodable {
            let x: Double, y: Double, w: Double, h: Double
        }
        struct Screen: Decodable {
            let x: Double, y: Double, width: Double, height: Double
            let focused: Bool
        }
        let elements: [Element]
        let screen: Screen
        let viewportHeight: Double
    }

    // MARK: - DOM extraction script

    private static let extractionJS = #"""
    (() => {
        const results = [];
        let nextId = 1;
        const LIMIT = 500;

        const TAG_ROLES = {
            A:'AXLink', BUTTON:'AXButton', SELECT:'AXPopUpButton',
            TEXTAREA:'AXTextArea', SUMMARY:'AXDisclosureTriangle'
        };
        const ARIA_ROLES = {
            button:'AXButton', link:'AXLink', menuitem:'AXMenuItem',
            tab:'AXTab', checkbox:'AXCheckBox', radio:'AXRadioButton',
            switch:'AXSwitch', slider:'AXSlider', combobox:'AXComboBox',
            textbox:'AXTextField', searchbox:'AXTextField', option:'AXRow',
            menuitemcheckbox:'AXCheckBox', menuitemradio:'AXRadioButton',
            treeitem:'AXOutlineRow', listbox:'AXList', tree:'AXOutline',
            grid:'AXTable', row:'AXRow', gridcell:'AXCell',
            progressbar:'AXProgressIndicator'
        };

        function inputRole(el) {
            const t = (el.type || 'text').toLowerCase();
            if (t === 'checkbox') return 'AXCheckBox';
            if (t === 'radio') return 'AXRadioButton';
            if (t === 'range') return 'AXSlider';
            if (t === 'submit' || t === 'button' || t === 'reset') return 'AXButton';
            return 'AXTextField';
        }

        function getLabel(el) {
            return el.getAttribute('aria-label')
                || el.getAttribute('title')
                || el.getAttribute('placeholder')
                || el.getAttribute('alt')
                || (el.labels && el.labels[0]?.textContent?.trim())
                || el.innerText?.trim()?.substring(0, 120)
                || null;
        }

        function visible(el) {
            const r = el.getBoundingClientRect();
            if (r.width <= 0 || r.height <= 0 || r.right <= 0 || r.bottom <= 0 || r.left >= innerWidth || r.top >= innerHeight) return false;
            const s = getComputedStyle(el);
            return s.visibility !== 'hidden' && s.display !== 'none'
                && parseFloat(s.opacity) > 0;
        }

        function walk(node) {
            if (nextId > LIMIT || node.nodeType !== 1) return;
            try { if (!visible(node)) return; } catch(e) { return; }

            const tag = node.tagName;
            const role = node.getAttribute('role');
            let axRole = null;

            if (role && ARIA_ROLES[role]) axRole = ARIA_ROLES[role];
            else if (tag === 'INPUT') axRole = inputRole(node);
            else if (TAG_ROLES[tag]) axRole = TAG_ROLES[tag];
            else if (node.hasAttribute('contenteditable')
                     && node.contentEditable === 'true') axRole = 'AXTextArea';
            else {
                try {
                    if (getComputedStyle(node).cursor === 'pointer'
                        || (node.hasAttribute('tabindex')
                            && parseInt(node.getAttribute('tabindex')) >= 0))
                        axRole = 'AXButton';
                } catch(e) {}
            }

            if (axRole) {
                const r = node.getBoundingClientRect();
                const l = getLabel(node);
                const v = node.value
                    || node.getAttribute('aria-valuenow') || null;
                if (l || v) {
                    results.push({
                        id: nextId++, role: axRole, label: l, value: v,
                        enabled: !node.disabled
                            && node.getAttribute('aria-disabled') !== 'true',
                        focused: node === document.activeElement,
                        actions: ['AXPress'],
                        rect: {x:r.x, y:r.y, w:r.width, h:r.height}
                    });
                    // Keep descending: parent controls may contain editable children.
                }
            }

            // Leaf text nodes for context
            if (!axRole && node.children.length === 0) {
                const text = node.textContent?.trim();
                if (text && text.length > 0 && text.length < 200) {
                    const r = node.getBoundingClientRect();
                    if (r.width > 0 && r.height > 0) {
                        results.push({
                            id: nextId++, role: 'AXStaticText',
                            label: text.substring(0, 120), value: null,
                            enabled: true, focused: false, actions: [],
                            rect: {x:r.x, y:r.y, w:r.width, h:r.height}
                        });
                    }
                }
            }

            for (const child of node.children) walk(child);
        }

        walk(document.body || document.documentElement);
        return JSON.stringify({
            elements: results, viewportHeight: window.innerHeight,
            screen: {x: window.screenX, y: window.screenY,
                width: window.outerWidth, height: window.outerHeight,
                focused: document.hasFocus() && document.visibilityState === 'visible'}
        });
    })()
    """#
}
