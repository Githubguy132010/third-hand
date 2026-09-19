// Regenerate with: swift Scripts/generate-icon.swift
import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent(".build/AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(_ pixels: Int) throws -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let transform = NSAffineTransform()
    transform.scale(by: CGFloat(pixels) / 1024)
    transform.concat()
    NSColor(calibratedRed: 0.12, green: 0.17, blue: 0.19, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 200, yRadius: 200).fill()
    NSColor(calibratedRed: 0.92, green: 0.95, blue: 0.84, alpha: 1).setStroke()
    // Three raised fingers and an open palm, drawn from simple original paths.
    let hand = NSBezierPath()
    hand.lineWidth = 78
    hand.lineCapStyle = .round
    hand.lineJoinStyle = .round
    hand.move(to: NSPoint(x: 352, y: 690))
    hand.line(to: NSPoint(x: 352, y: 442))
    hand.curve(to: NSPoint(x: 676, y: 442), controlPoint1: NSPoint(x: 352, y: 208), controlPoint2: NSPoint(x: 676, y: 208))
    hand.line(to: NSPoint(x: 676, y: 640))
    hand.stroke()
    for (x, top) in [(460.0, 752.0), (568.0, 728.0)] {
        let finger = NSBezierPath()
        finger.lineWidth = 78
        finger.lineCapStyle = .round
        finger.move(to: NSPoint(x: x, y: 484))
        finger.line(to: NSPoint(x: x, y: top))
        finger.stroke()
    }
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try render(size).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(size * 2).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
try render(512).write(to: root.appendingPathComponent("Resources/AppIcon.png"))
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try task.run()
task.waitUntilExit()
guard task.terminationStatus == 0 else { fatalError("Icon conversion failed") }
