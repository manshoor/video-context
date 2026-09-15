import AppKit
import Foundation

// Vector source of truth. Render all standard macOS icon representations.
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func drawIcon() {
    let plate = NSBezierPath(roundedRect: NSRect(x: 72, y: 72, width: 880, height: 880), xRadius: 196, yRadius: 196)
    let gradient = NSGradient(starting: NSColor(red: 0.38, green: 0.35, blue: 0.94, alpha: 1), ending: NSColor(red: 0.16, green: 0.15, blue: 0.55, alpha: 1))!
    gradient.draw(in: plate, angle: -75)
    NSColor.white.withAlphaComponent(0.23).setStroke()
    plate.lineWidth = 3
    plate.stroke()

    let brackets = NSBezierPath()
    brackets.move(to: NSPoint(x: 346, y: 716))
    brackets.line(to: NSPoint(x: 276, y: 716))
    brackets.line(to: NSPoint(x: 276, y: 308))
    brackets.line(to: NSPoint(x: 346, y: 308))
    brackets.move(to: NSPoint(x: 678, y: 716))
    brackets.line(to: NSPoint(x: 748, y: 716))
    brackets.line(to: NSPoint(x: 748, y: 308))
    brackets.line(to: NSPoint(x: 678, y: 308))
    brackets.lineWidth = 40
    brackets.lineJoinStyle = .round
    brackets.lineCapStyle = .round
    NSColor.white.withAlphaComponent(0.94).setStroke()
    brackets.stroke()

    let play = NSBezierPath()
    play.move(to: NSPoint(x: 444, y: 662))
    play.curve(to: NSPoint(x: 418, y: 645), controlPoint1: NSPoint(x: 432, y: 670), controlPoint2: NSPoint(x: 418, y: 661))
    play.line(to: NSPoint(x: 418, y: 379))
    play.curve(to: NSPoint(x: 444, y: 362), controlPoint1: NSPoint(x: 418, y: 363), controlPoint2: NSPoint(x: 432, y: 354))
    play.line(to: NSPoint(x: 643, y: 495))
    play.curve(to: NSPoint(x: 643, y: 529), controlPoint1: NSPoint(x: 658, y: 503), controlPoint2: NSPoint(x: 658, y: 521))
    play.close()
    NSColor.white.setFill()
    play.fill()
}

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let transform = AffineTransform(scale: Double(pixels) / 1024)
        (transform as NSAffineTransform).concat()
        drawIcon()
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        let data = bitmap.representation(using: .png, properties: [:])!
        try data.write(to: output.appending(path: "icon_\(points)x\(points)\(suffix).png"))
    }
}
