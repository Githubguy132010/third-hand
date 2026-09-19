import XCTest
@testable import ThirdHand

@MainActor
final class TextFieldFocusTests: XCTestCase {
    func testAlreadyFocusedFieldDoesNotRequireClickableBounds() async throws {
        try await TextFieldFocus.prepare(check: {}, probe: { true }, requestFocus: {
            XCTFail("Already focused field needs no focus mutation")
        }, click: {
            XCTFail("Already focused field must not be clicked again")
            throw TextFieldFocus.Failure.unavailable
        })
    }

    func testAccessibilityFocusWorksWithoutClick() async throws {
        var focused = false
        try await TextFieldFocus.prepare(interval: 1, check: {}, probe: { focused }, requestFocus: {
            focused = true
        }, click: { XCTFail("Successful AX focus must not require a click") })
    }

    func testClickFallbackStillRequiresConfirmedFocus() async throws {
        var focused = false
        var clicks = 0
        try await TextFieldFocus.prepare(attempts: 2, interval: 1, check: {}, probe: { focused },
                                        requestFocus: {}, click: {
            clicks += 1
            focused = true
        })
        XCTAssertEqual(clicks, 1)
    }

    func testClickWithoutFocusCannotProceedToTyping() async {
        do {
            try await TextFieldFocus.prepare(attempts: 1, interval: 1, check: {}, probe: { false },
                                            requestFocus: {}, click: {})
            XCTFail("Click alone cannot authorize typing")
        } catch { XCTAssertEqual(error as? TextFieldFocus.Failure, .unavailable) }
    }

    func testAcceptsFieldAndInnerEditorButRejectsSiblingAndContainer() {
        let parents = ["editor": "field", "field": "window", "other": "window"]
        for focused in ["field", "editor"] {
            XCTAssertTrue(TextFieldFocus.contains(focused, target: "field", equal: ==, parent: { parents[$0] }))
        }
        for focused in ["other", "window"] {
            XCTAssertFalse(TextFieldFocus.contains(focused, target: "field", equal: ==, parent: { parents[$0] }))
        }
    }

    func testBrokenParentCycleIsBounded() {
        XCTAssertFalse(TextFieldFocus.contains("other", target: "field", equal: ==, parent: { $0 }))
    }

    func testWaitAcceptsDelayedFocus() async throws {
        var probes = 0
        try await TextFieldFocus.wait(attempts: 4, interval: 1, check: {}) {
            probes += 1
            return probes == 3
        }
        XCTAssertEqual(probes, 3)
    }

    func testUnconfirmedFocusStopsBeforeTyping() async {
        var typed = false
        do {
            try await TextFieldFocus.wait(attempts: 2, interval: 1, check: {}) { false }
            typed = true
            XCTFail("Unconfirmed focus must fail")
        } catch {
            XCTAssertEqual(error as? TextFieldFocus.Failure, .unavailable)
        }
        XCTAssertFalse(typed)
    }

    func testAppChangeDuringProbeStopsEvenWhenFieldReportsFocus() async {
        var appChanged = false
        do {
            try await TextFieldFocus.wait(interval: 1, check: {
                if appChanged { throw TextFieldFocus.Failure.changed }
            }) {
                appChanged = true
                return true
            }
            XCTFail("App change must abort entry")
        } catch {
            XCTAssertEqual(error as? TextFieldFocus.Failure, .changed)
        }
    }

    func testCancellationStopsFocusPolling() async {
        let task = Task {
            try await TextFieldFocus.wait(check: {}) {
                withUnsafeCurrentTask { $0?.cancel() }
                return true
            }
        }
        do {
            try await task.value
            XCTFail("Cancellation must abort entry")
        } catch { XCTAssertTrue(error is CancellationError) }
    }
}
