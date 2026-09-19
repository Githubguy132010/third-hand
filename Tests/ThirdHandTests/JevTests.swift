import XCTest
import ApplicationServices
@testable import ThirdHand

final class JevTests: XCTestCase {
    func element(_ id: Int, _ role: String, enabled: Bool = true) -> AccessibilityElement {
        AccessibilityElement(id: id, role: role, label: "Control", value: "", enabled: enabled, actions: [], axElement: AXUIElementCreateSystemWide())
    }

    func testOnlyCompatibleEnabledControlsAreOffered() {
        let controls = [element(1, "AXButton"), element(2, "AXTextField"), element(3, "AXTextField", enabled: false), element(4, "AXStaticText")]
        let targets = JevClient.targets(controls)
        XCTAssertEqual(Set(targets["CLICK"]!.keys), ["1", "2"])
        XCTAssertEqual(Set(targets["TYPE_TEXT"]!.keys), ["2"])
        XCTAssertTrue(JevClient.targets([element(1, "AXWebArea")]).isEmpty)
    }

    func testSelectorDoesNotGenerateTextOrSendScreenshots() throws {
        let body = JevClient.requestBody(goal: "Search music", elements: [element(1, "AXTextField")], appName: "Example", history: [])
        XCTAssertEqual(body["model"] as? String, "typesafe/jev-1.13")
        let questions = body["questions"] as! [String: Any]
        XCTAssertNotNil(questions["type_text_target"])
        XCTAssertNil(questions["type_text_value"])
        XCTAssertNil(body["messages"])
    }

    func testTextDecisionRetainsTargetForSeparateGenerator() throws {
        let data = Data(#"{"answers":{"operation":{"choice":"TYPE_TEXT","confidence":0.99},"type_text_target":{"choice":"2","confidence":0.99}}}"#.utf8)
        let decision = try JevClient.decode(data, elements: [element(2, "AXTextField")])
        XCTAssertEqual(decision.targetIndex, "2")
        XCTAssertNil(decision.textValue)
    }

    func testRejectsWrongTargetAndUnsupportedOperation() {
        let wrongTarget = Data(#"{"answers":{"operation":{"choice":"TYPE_TEXT","confidence":0.99},"type_text_target":{"choice":"1","confidence":0.99}}}"#.utf8)
        XCTAssertThrowsError(try JevClient.decode(wrongTarget, elements: [element(1, "AXButton"), element(2, "AXTextField")]))
        let unsupported = Data(#"{"answers":{"operation":{"choice":"TYPE_TEXT","confidence":0.99}}}"#.utf8)
        XCTAssertThrowsError(try JevClient.decode(unsupported, elements: [element(1, "AXButton")]))
    }

    func testSelectorAndTextHelperUseSeparateRequestsWithSameKey() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FastPathProtocol.self]
        let client = OpenRouterClient(apiKey: "fixture-key", session: URLSession(configuration: config))
        let field = element(2, "AXTextField")
        let decision = try await client.selectControl(goal: "Search Boards of Canada", elements: [field], appName: "Test", history: [])
        XCTAssertEqual(decision.targetIndex, "2")
        XCTAssertNil(decision.textValue)
        let text = try await client.fieldText(goal: "Search Boards of Canada", field: field, elements: [field], appName: "Test", history: [])
        XCTAssertEqual(text, "Boards of Canada")
    }

    func testSearchSubmissionDoesNotRequireAnotherTextCall() throws {
        let data = Data(#"{"answers":{"operation":{"choice":"PRESS_RETURN","confidence":0.99}}}"#.utf8)
        let decision = try JevClient.decode(data, elements: [])
        XCTAssertEqual(decision.operation, "KEY_PRESS")
        XCTAssertEqual(decision.key, "return")
        try decision.validate(elements: [], hasScreenshot: false)
    }
}

private final class FastPathProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-key")
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
        let payload: String
        if request.url?.path == "/api/alpha/decisions" {
            XCTAssertEqual(body["model"] as? String, "typesafe/jev-1.13")
            XCTAssertNil(body["messages"])
            payload = #"{"answers":{"operation":{"choice":"TYPE_TEXT","confidence":0.99},"type_text_target":{"choice":"2","confidence":0.99}}}"#
        } else {
            XCTAssertEqual(request.url?.path, "/api/v1/chat/completions")
            XCTAssertEqual(body["model"] as? String, OpenRouterClient.defaultModel)
            let messages = body["messages"] as! [[String: Any]]
            let context = try! JSONSerialization.jsonObject(with: Data((messages[1]["content"] as! String).utf8)) as! [String: Any]
            XCTAssertEqual((context["field"] as! [String: String])["role"], "AXTextField")
            XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("image_url"))
            payload = #"{"choices":[{"message":{"content":"{\"text\":\"Boards of Canada\"}"}}]}"#
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(payload.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
