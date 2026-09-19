import XCTest
import AppKit
@testable import ThirdHand

@MainActor
final class LocalPerceptionTests: XCTestCase {
    private func element(id: Int, label: String, role: String = "AXButton", source: String = "accessibility", x: CGFloat = 20) -> AccessibilityElement {
        AccessibilityElement(id: id, role: role, label: label, value: nil, enabled: true, actions: [], axElement: nil,
            frame: CGRect(x: x, y: 20, width: 100, height: 30), source: source)
    }

    func testOCRMergePreservesControlsAndAddsDistinctTextRegions() {
        let controls = [element(id: 8, label: "Save")]
        let ocr = [element(id: 1, label: "Save", role: "AXStaticText", source: "ocr"),
                   element(id: 2, label: "Cancel", role: "AXStaticText", source: "ocr", x: 150)]
        let result = VisionObserver.merging(ocr: ocr, with: controls)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].id, 8)
        XCTAssertEqual(result[0].source, "accessibility")
        XCTAssertEqual(result[1].id, 9)
        XCTAssertEqual(result[1].role, "AXStaticText")
        XCTAssertEqual(result[1].source, "ocr")
        XCTAssertTrue(result[1].actions.isEmpty)
    }

    func testSameLabelAtDifferentLocationIsNotDiscarded() {
        let result = VisionObserver.merging(ocr: [element(id: 1, label: "Save", role: "AXStaticText", source: "ocr", x: 300)],
            with: [element(id: 1, label: "Save")])
        XCTAssertEqual(result.count, 2)
        XCTAssertNotEqual(result[0].id, result[1].id)
    }

    func testAppleVisionReadsLocalPixelsAndMapsToScreen() throws {
        let image = NSImage(size: NSSize(width: 600, height: 200))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 600, height: 200).fill()
        ("Save Document" as NSString).draw(at: NSPoint(x: 40, y: 90), withAttributes: [
            .font: NSFont.systemFont(ofSize: 40), .foregroundColor: NSColor.black
        ])
        image.unlockFocus()
        var rect = CGRect(x: 0, y: 0, width: 600, height: 200)
        let pixels = try XCTUnwrap(image.cgImage(forProposedRect: &rect, context: nil, hints: nil))
        let frame = CGRect(x: -1000, y: 200, width: 600, height: 200)
        let results = try VisionObserver.extractElements(from: pixels, windowFrame: frame)
        let text = try XCTUnwrap(results.first { $0.displayLabel.contains("Save Document") })
        XCTAssertEqual(text.source, "ocr")
        XCTAssertEqual(text.role, "AXStaticText")
        XCTAssertTrue(text.actions.isEmpty)
        XCTAssertTrue(frame.contains(try XCTUnwrap(text.frame)))
    }

    func testLocalTextContextIncludesSelectedFieldAndBoundsScreenData() throws {
        let field = element(id: 1, label: "Message", role: "AXTextArea")
        let elements = (0..<500).map { element(id: $0, label: String(repeating: "x", count: 1000)) }
        let context = try LocalTextGenerator.context(goal: "Write a greeting", field: field, elements: elements, appName: "Test", history: [])
        XCTAssertLessThan(context.utf8.count, 2500)
        XCTAssertTrue(context.contains("Message"))
        XCTAssertTrue(context.contains("Write a greeting"))
        XCTAssertThrowsError(try LocalTextGenerator.context(goal: String(repeating: "x", count: 4001), field: field, elements: [], appName: "Test", history: []))
    }

    func testLiteralEntryNeedsNoModelOrNetwork() async throws {
        let field = element(id: 1, label: "Search", role: "AXTextField")
        let text = try await LocalTextGenerator.fieldText(goal: "search for Boards of Canada", field: field, elements: [], appName: "Test", history: [])
        XCTAssertEqual(text, "Boards of Canada")
    }

    func testInstalledAppleModelGeneratesCompleteTextWhenOptedIn() async throws {
        guard ProcessInfo.processInfo.environment["THIRDHAND_LOCAL_SMOKE"] == "1" else {
            throw XCTSkip("Set THIRDHAND_LOCAL_SMOKE=1 to exercise the installed on-device language model.")
        }
        guard LocalTextGenerator.available else { throw XCTSkip(LocalTextGenerator.status) }
        let field = element(id: 1, label: "Message", role: "AXTextArea")
        let text = try await LocalTextGenerator.fieldText(goal: "Write one short friendly greeting to Sam.", field: field, elements: [field], appName: "Test", history: [])
        XCTAssertFalse(text.isEmpty)
        XCTAssertTrue(text.localizedCaseInsensitiveContains("Sam"))
        XCTAssertLessThan(text.count, 500)
    }
}
