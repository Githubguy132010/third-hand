import ScreenCaptureKit
import Vision

enum VisionObserver {

    static func observe(pid: pid_t) async throws -> [AccessibilityElement] {
        guard CGPreflightScreenCaptureAccess() else {
            throw ControllerError.invalid("Screen Recording required for vision observation")
        }
        guard let front = WindowSnapshot.frontWindow(pid: pid) else {
            throw ControllerError.invalid("No visible window for OCR")
        }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == front.id }) else {
            throw ControllerError.invalid("Window unavailable for capture")
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        config.width = max(1, Int(window.frame.width * scale))
        config.height = max(1, Int(window.frame.height * scale))
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return extractElements(from: image, windowFrame: front.frame)
    }

    private static func extractElements(from image: CGImage, windowFrame: CGRect) -> [AccessibilityElement] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try? handler.perform([request])

        guard let results = request.results else { return [] }

        var elements: [AccessibilityElement] = []
        var nextId = 1

        for observation in results.prefix(500) {
            guard let candidate = observation.topCandidates(1).first,
                  candidate.confidence > 0.3 else { continue }

            let box = observation.boundingBox
            let screenRect = CGRect(
                x: windowFrame.minX + box.minX * windowFrame.width,
                y: windowFrame.minY + (1 - box.maxY) * windowFrame.height,
                width: box.width * windowFrame.width,
                height: box.height * windowFrame.height
            )

            let text = candidate.string.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }

            let isControl = text.count < 40
            elements.append(AccessibilityElement(
                id: nextId,
                role: isControl ? "AXButton" : "AXStaticText",
                label: text,
                value: nil,
                enabled: true,
                actions: isControl ? ["AXPress"] : [],
                axElement: nil,
                frame: screenRect
            ))
            nextId += 1
        }

        Log.info("VisionObserver: \(elements.count) elements from OCR")
        return elements
    }
}
