import XCTest
@testable import ThirdHand

@MainActor
final class TextEntryPlanTests: XCTestCase {
    func testSearchCandidatesNeverIncludeOldScreenContent() {
        let candidates = TextEntryPlan.candidates("search for Ninajirachi")
        XCTAssertEqual(candidates.first, "Ninajirachi")
        XCTAssertFalse(candidates.contains { $0.localizedCaseInsensitiveContains("skyfall") || $0.localizedCaseInsensitiveContains("adele") })
    }

    func testDirectoryCommandQuotesShellMetacharactersAndHome() throws {
        let plan = try TextEntryPlan.build(kind: "change_directory", content: "/tmp/Shiv's $(touch nope); music", terminal: true)
        XCTAssertEqual(plan.text, "cd -- '/tmp/Shiv'\\''s $(touch nope); music'")
        let home = try TextEntryPlan.build(kind: "change_directory", content: "~/My Music", terminal: true)
        XCTAssertTrue(home.text.hasPrefix("cd -- \"$HOME\"/'My Music'"))
        XCTAssertThrowsError(try TextEntryPlan.build(kind: "change_directory", content: "/tmp\nls", terminal: true))
        XCTAssertThrowsError(try TextEntryPlan.build(kind: "change_directory", content: "/tmp", terminal: false))
        XCTAssertThrowsError(try TextEntryPlan.build(kind: "unsupported", content: "Write an essay", terminal: false))
    }

    func testDirectoryVerificationRequiresFreshPwdOutput() throws {
        let plan = try TextEntryPlan.build(kind: "change_directory", content: "/tmp", terminal: true)
        XCTAssertEqual(plan.text, "cd -- '/tmp'")
        XCTAssertFalse(plan.text.contains("printf"))
        let before = "$ pwd\n/old\n$ "
        XCTAssertNil(TextEntryPlan.directoryResult(before: before, after: before))
        XCTAssertNil(TextEntryPlan.directoryResult(before: before, after: before + "pwd"))
        XCTAssertEqual(TextEntryPlan.directoryResult(before: before, after: before + "pwd\n/private/tmp\n$ "), "/private/tmp")
        XCTAssertNil(TextEntryPlan.directoryResult(before: before, after: before + "pwd\nerror\n$ "))
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
        XCTAssertEqual(Set(questions.keys), ["intent", "content"])
        XCTAssertEqual(questions["intent"]?["type"] as? String, "choice")
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"answers":{"intent":{"choice":"search"},"content":{"choice":"0"}}}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
