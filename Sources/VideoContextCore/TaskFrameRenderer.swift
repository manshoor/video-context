import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

public enum TaskFrameRenderer {
    @concurrent
    public static func render(url: URL, annotations: [TaskAnnotation], crop: NormalizedCrop? = nil) async throws -> Data {
        try Task.checkCancellation()
        guard annotations.allSatisfy(\.isValid), let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw VideoFrameError.frameUnavailable }
        let scale = min(1, 2000 / Double(max(image.width, image.height)))
        let width = max(1, Int(Double(image.width) * scale)), height = max(1, Int(Double(image.height) * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw VideoFrameError.frameUnavailable }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let w = Double(width), h = Double(height)
        for (index, item) in annotations.enumerated() {
            try Task.checkCancellation()
            let rect = CGRect(x: item.x * w, y: (1 - item.y - item.height) * h, width: item.width * w, height: item.height * h)
            context.setStrokeColor(CGColor(red: 1, green: 0.22, blue: 0.12, alpha: 1)); context.setLineWidth(max(3, w / 350))
            if item.kind == .rectangle { context.stroke(rect) }
            if item.kind == .arrow {
                let start = CGPoint(x: item.flipHorizontal == true ? rect.maxX : rect.minX, y: item.flipVertical == true ? rect.minY : rect.maxY)
                let end = CGPoint(x: item.flipHorizontal == true ? rect.minX : rect.maxX, y: item.flipVertical == true ? rect.maxY : rect.minY)
                let angle = atan2(end.y - start.y, end.x - start.x), tip = max(12, w / 65)
                context.move(to: start); context.addLine(to: end)
                context.move(to: CGPoint(x: end.x - tip * cos(angle - 0.5), y: end.y - tip * sin(angle - 0.5)))
                context.addLine(to: end); context.addLine(to: CGPoint(x: end.x - tip * cos(angle + 0.5), y: end.y - tip * sin(angle + 0.5)))
                context.strokePath()
            }
            // Numbered labels link to the complete text returned in MCP metadata.
            let text = "\(index + 1). \(item.text)"
            let font = CTFontCreateWithName("Helvetica-Bold" as CFString, max(13, w / 85), nil)
            let attributed = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font, NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1)])
            let labelWidth = max(30, min(w - rect.minX, max(rect.width, w * 0.3)))
            let setter = CTFramesetterCreateWithAttributedString(attributed)
            let measured = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(location: 0, length: 0), nil, CGSize(width: max(1, labelWidth - 8), height: 90), nil)
            let labelHeight = min(90, max(24, ceil(measured.height) + 8))
            let labelY = rect.maxY + labelHeight <= h ? rect.maxY : max(0, rect.maxY - labelHeight)
            let label = CGRect(x: rect.minX, y: labelY, width: labelWidth, height: labelHeight)
            context.setFillColor(CGColor(gray: 0, alpha: 0.82)); context.fill(label)
            CTFrameDraw(CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), CGPath(rect: label.insetBy(dx: 4, dy: 4), transform: nil), nil), context)
        }
        guard var output = context.makeImage() else { throw VideoFrameError.frameUnavailable }
        if let crop {
            // CGImage cropping uses top-left image coordinates.
            let rect = CGRect(x: crop.x * w, y: crop.y * h, width: crop.width * w, height: crop.height * h)
            guard let cropped = output.cropping(to: rect) else { throw VideoFrameError.invalidCrop }
            output = cropped
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { throw VideoFrameError.frameUnavailable }
        CGImageDestinationAddImage(destination, output, [kCGImageDestinationLossyCompressionQuality: 0.72] as CFDictionary)
        guard CGImageDestinationFinalize(destination), data.length <= 4_000_000 else { throw TaskContextError.invalid("The requested annotated frame exceeds the image size limit. Request a crop.") }
        return data as Data
    }
}
