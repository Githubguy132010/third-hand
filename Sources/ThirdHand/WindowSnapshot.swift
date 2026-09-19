import AppKit
import ScreenCaptureKit

struct WindowSnapshot {
    let windowID: CGWindowID
    let frame: CGRect // Global Quartz coordinates, top-left origin.
    let base64JPEG: String

    static func frontWindow(pid: pid_t) -> (id: CGWindowID, frame: CGRect)? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for window in windows {
            guard window[kCGWindowOwnerPID as String] as? Int32 == pid,
                  window[kCGWindowLayer as String] as? Int == 0,
                  let id = window[kCGWindowNumber as String] as? UInt32,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds), frame.width > 1, frame.height > 1 else { continue }
            return (id, frame)
        }
        return nil
    }

    static func capture(pid: pid_t) async throws -> WindowSnapshot {
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            throw ControllerError.invalid("Enable Screen Recording for Third Hand in System Settings, then relaunch to control custom interfaces.")
        }
        guard let front = frontWindow(pid: pid) else { throw ControllerError.invalid("No visible target window") }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == front.id }) else {
            throw ControllerError.invalid("Target window is unavailable for capture")
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let scale = min(1, 1600 / max(window.frame.width, window.frame.height))
        config.width = max(1, Int(window.frame.width * scale))
        config.height = max(1, Int(window.frame.height * scale))
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.75]) else {
            throw ControllerError.invalid("Could not encode window screenshot")
        }
        return WindowSnapshot(windowID: window.windowID, frame: window.frame, base64JPEG: jpeg.base64EncodedString())
    }

    func point(x: Double, y: Double) -> CGPoint {
        CGPoint(x: frame.minX + x * (frame.width - 1), y: frame.minY + y * (frame.height - 1))
    }
}
