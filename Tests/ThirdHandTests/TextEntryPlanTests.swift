import XCTest
@testable import ThirdHand

@MainActor
final class TextEntryPlanTests: XCTestCase {
    func testSearchCandidatesNeverIncludeOldScreenContent() {
        let candidates = TextEntryPlan.candidates("search for Ninajirachi")
        XCTAssertEqual(candidates.first, "Ninajirachi")
        XCTAssertFalse(candidates.contains { $0.localizedCaseInsensitiveContains("skyfall") || $0.localizedCaseInsensitiveContains("adele") })
    }

    func testLiteralCommandIsPreservedWithoutAddedCommands() throws {
        let command = "cd '/tmp/My Project'"
        let plan = try TextEntryPlan.build(kind: "literal", content: command, terminal: true)
        XCTAssertEqual(plan.text, command)
        XCTAssertThrowsError(try TextEntryPlan.build(kind: "change_directory", content: "/tmp", terminal: true))
        XCTAssertThrowsError(try TextEntryPlan.build(kind: "unsupported", content: "go into my project", terminal: true))
    }

    func testJevSelectsSearchTextWithoutASecondModel() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TextSelectionProtocol.self]
        let client = JevClient(apiKey: "fixture", session: URLSession(configuration: config))
        let field = AccessibilityElement(id: 1, role: "AXTextField", label: "Search", value: "Skyfall Adele", enabled: true, actions: [], axElement: nil)
        let plan = try await client.selectText(goal: "search for Ninajirachi", field: field, appName: "Spotify", terminal: false)
        XCTAssertEqual(plan.kind, "search")
        XCTAssertEqual(plan.text, "Ninajirachi")
    }
}

private final class TextSelectionProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
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
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("Skyfall"))
        XCTAssertFalse(text.contains("Adele"))
        let body = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        let questions = body["questions"] as! [String: [String: Any]]
        let state = body["state"] as! [String: Any]
        if questions["intent"] != nil {
            XCTAssertEqual(Set(questions.keys), ["intent"])
            XCTAssertNil(state["selectedIntent"])
        } else {
            XCTAssertEqual(Set(questions.keys), ["content"])
            XCTAssertEqual(state["selectedIntent"] as? String, "search")
            XCTAssertTrue((questions["content"]?["instructions"] as? String)?.contains("Do NOT paste the full task sentence") == true)
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"answers":{"intent":{"choice":"search"},"content":{"choice":"0"}}}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
