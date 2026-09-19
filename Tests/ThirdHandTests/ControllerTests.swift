import XCTest
import ApplicationServices
@testable import ThirdHand

final class ControllerTests: XCTestCase {
    private func element(enabled: Bool = true) -> AccessibilityElement {
        AccessibilityElement(id: 1, role: "AXTextField", label: "Search", value: "", enabled: enabled,
                             actions: [], axElement: AXUIElementCreateSystemWide())
    }

    func testGeneratedTextPreservesFullPhrase() throws {
        let payload = #"{"choices":[{"message":{"content":"{\"operation\":\"TYPE_TEXT\",\"targetIndex\":\"1\",\"textValue\":\"Boards of Canada – Music Has the Right to Children\"}"}}]}"#
        let decision = try OpenRouterClient.decode(Data(payload.utf8))
        XCTAssertEqual(decision.textValue, "Boards of Canada – Music Has the Right to Children")
        try decision.validate(elements: [element()], hasScreenshot: false)
    }

    func testRejectsMissingTextAndInvalidTargets() {
        XCTAssertThrowsError(try AgentDecision(operation: "TYPE_TEXT", targetIndex: "1").validate(elements: [element()], hasScreenshot: false))
        XCTAssertThrowsError(try AgentDecision(operation: "CLICK", targetIndex: "2").validate(elements: [element()], hasScreenshot: false))
        XCTAssertThrowsError(try AgentDecision(operation: "CLICK", targetIndex: "1").validate(elements: [element(enabled: false)], hasScreenshot: false))
    }

    func testTextCannotTargetNonEditableControls() {
        let button = AccessibilityElement(id: 1, role: "AXButton", label: "Play", value: nil,
            enabled: true, actions: [], axElement: AXUIElementCreateSystemWide())
        XCTAssertThrowsError(try AgentDecision(operation: "TYPE_TEXT", targetIndex: "1", textValue: "hello")
            .validate(elements: [button], hasScreenshot: false))
    }

    func testVisualActionsRequireImageAndBoundedCoordinates() throws {
        let decision = AgentDecision(operation: "CLICK", x: 0.2, y: 0.8)
        try decision.validate(elements: [], hasScreenshot: true)
        XCTAssertThrowsError(try decision.validate(elements: [], hasScreenshot: false))
        XCTAssertThrowsError(try AgentDecision(operation: "CLICK", x: 1.1, y: 0.8).validate(elements: [], hasScreenshot: true))
        XCTAssertThrowsError(try AgentDecision(operation: "CLICK", x: 0.5).validate(elements: [], hasScreenshot: true))
    }

    func testShortcutValidation() throws {
        try AgentDecision(operation: "KEY_PRESS", key: "f3").validate(elements: [], hasScreenshot: false)
        XCTAssertThrowsError(try AgentDecision(operation: "KEY_PRESS", key: "shell").validate(elements: [], hasScreenshot: false))
        XCTAssertThrowsError(try AgentDecision(operation: "KEY_PRESS", key: "a", modifiers: ["invalid"]).validate(elements: [], hasScreenshot: false))
    }

    func testCoordinatesOnDisplayLeftOfPrimary() {
        let snapshot = WindowSnapshot(windowID: 1, frame: CGRect(x: -1920, y: 100, width: 1000, height: 800), base64JPEG: "")
        XCTAssertEqual(snapshot.point(x: 0, y: 0), CGPoint(x: -1920, y: 100))
        XCTAssertEqual(snapshot.point(x: 1, y: 1), CGPoint(x: -921, y: 899))
        XCTAssertTrue(snapshot.frame.contains(snapshot.point(x: 1, y: 1)))
    }

    func testMalformedResponseFailsCleanly() {
        for payload in ["{}", "not json", #"{"choices":[]}"#] {
            XCTAssertThrowsError(try OpenRouterClient.decode(Data(payload.utf8)))
        }
    }

    func testChatRequestIncludesContextAndImage() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockProtocol.self]
        let client = OpenRouterClient(apiKey: "test-key", baseURL: "https://example.invalid/api/v1", session: URLSession(configuration: config))
        let result = try await client.decide(goal: "Search for Boards of Canada", elements: [], appName: "Spotify", screenshot: "aW1hZ2U=")
        XCTAssertEqual(result.operation, "CLICK")
    }
    func testSchemaRequiresTargetFieldsAndRestrictsObservedIDs() throws {
        let format = OpenRouterClient.responseFormat(elements: [element(), element(enabled: false)])
        XCTAssertEqual(format["type"] as? String, "json_schema")
        let wrapper = format["json_schema"] as! [String: Any]
        XCTAssertEqual(wrapper["strict"] as? Bool, true)
        let schema = wrapper["schema"] as! [String: Any]
        let required = schema["required"] as! [String]
        XCTAssertTrue(["targetIndex", "x", "y", "textValue"].allSatisfy(required.contains))
        let properties = schema["properties"] as! [String: Any]
        let target = properties["targetIndex"] as! [String: Any]
        let ids = target["enum"] as! [Any]
        XCTAssertEqual(ids.compactMap { $0 as? String }, ["1"])
        XCTAssertTrue(ids.last is NSNull)
    }

    func testMissingTargetIsCorrectedBeforeReturningAction() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockProtocol.self]
        let client = OpenRouterClient(apiKey: "test-key", baseURL: "https://recover.invalid/api/v1", session: URLSession(configuration: config))
        let result = try await client.decide(goal: "Search for Boards of Canada", elements: [], appName: "Spotify", screenshot: "aW1hZ2U=")
        XCTAssertEqual(result.x, 0.5)
        XCTAssertEqual(result.y, 0.5)
    }

    func testRepeatedMissingTargetsStopAfterBoundedRetries() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockProtocol.self]
        let client = OpenRouterClient(apiKey: "test-key", baseURL: "https://reject.invalid/api/v1", session: URLSession(configuration: config))
        do {
            _ = try await client.decide(goal: "Search for Boards of Canada", elements: [], appName: "Spotify", screenshot: "aW1hZ2U=")
            XCTFail("Invalid actions must never reach the executor")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("after 3 attempts"))
        }
    }

}

private final class MockProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        XCTAssertEqual(request.url?.path, "/api/v1/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        let body = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(body["model"] as? String, OpenRouterClient.defaultModel)
        XCTAssertEqual((body["response_format"] as? [String: Any])?["type"] as? String, "json_schema")
        XCTAssertEqual((body["provider"] as? [String: Bool])?["require_parameters"], true)
        let messages = body["messages"] as! [[String: Any]]
        XCTAssertLessThanOrEqual(messages.count, 4)
        if messages.count > 2 {
            XCTAssertTrue((messages.last?["content"] as? String)?.contains("Missing action target") == true)
        }
        let content = messages[1]["content"] as! [[String: Any]]
        XCTAssertTrue((content[0]["text"] as! String).contains("Boards of Canada"))
        XCTAssertEqual((content[1]["image_url"] as! [String: String])["url"], "data:image/jpeg;base64,aW1hZ2U=")
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if request.url?.host == "reject.invalid" || (request.url?.host == "recover.invalid" && messages.count == 2) {
            client?.urlProtocol(self, didLoad: Data(#"{"choices":[{"message":{"content":"{\"operation\":\"TYPE_TEXT\",\"textValue\":\"Boards of Canada\"}"}}]}"#.utf8))
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        client?.urlProtocol(self, didLoad: Data(#"{"choices":[{"message":{"content":"{\"operation\":\"CLICK\",\"x\":0.5,\"y\":0.5}"}}]}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
