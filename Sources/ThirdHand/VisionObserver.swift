import ScreenCaptureKit
import Vision

enum VisionObserver {

    static func observe(pid: pid_t) async throws -> [AccessibilityElement] {
        let snapshot = try await WindowSnapshot.capture(pid: pid)
        guard let image = snapshot.image else { throw ControllerError.invalid("No local capture available") }
        let result = try extractElements(from: image, windowFrame: snapshot.frame)
        guard let current = WindowSnapshot.frontWindow(pid: pid), current.id == snapshot.windowID,
              current.frame == snapshot.frame else { throw ControllerError.invalid("Window changed during local OCR") }
        return result
    }

    /// OCR contributes text regions, never invented buttons or text fields.
    static func merging(ocr: [AccessibilityElement], with controls: [AccessibilityElement]) -> [AccessibilityElement] {
        var result = controls
        var nextID = (controls.map(\.id).max() ?? 0) + 1
        for text in ocr {
            let duplicate = controls.contains { control in
                guard let a = control.frame, let b = text.frame else { return false }
                return a.intersects(b) && control.displayLabel.localizedCaseInsensitiveContains(text.displayLabel)
            }
            guard !duplicate else { continue }
            result.append(AccessibilityElement(id: nextID, role: "AXStaticText", label: text.label,
                value: nil, enabled: true, actions: [], axElement: nil, frame: text.frame, source: "ocr"))
            nextID += 1
        }
        return result
    }

    static func extractElements(from image: CGImage, windowFrame: CGRect) throws -> [AccessibilityElement] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])

        guard let results = request.results else { return [] }

        var elements: [AccessibilityElement] = []
        var nextId = 1

        for observation in results.prefix(500) {
            guard let candidate = observation.topCandidates(1).first,
                  candidate.confidence >= 0.8 else { continue }

            let box = observation.boundingBox
            let screenRect = CGRect(
                x: windowFrame.minX + box.minX * windowFrame.width,
                y: windowFrame.minY + (1 - box.maxY) * windowFrame.height,
                width: box.width * windowFrame.width,
                height: box.height * windowFrame.height
            )

            let text = candidate.string.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }

            elements.append(AccessibilityElement(
                id: nextId,
                role: "AXStaticText",
                label: text,
                value: nil,
                enabled: true,
                actions: [],
                axElement: nil,
                frame: screenRect,
                source: "ocr"
            ))
            nextId += 1
        }

        Log.info("VisionObserver: \(elements.count) elements from OCR")
        return elements
    }
}
