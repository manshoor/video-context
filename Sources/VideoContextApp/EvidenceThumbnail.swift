import SwiftUI
import ImageIO
import UniformTypeIdentifiers

struct EvidenceThumbnail: View {
    let url: URL?
    @State private var image: NSImage?
    @State private var failed = false
    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: failed ? "photo.badge.exclamationmark" : "photo")
                    .foregroundStyle(.secondary)
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(.rect(cornerRadius: 8))
        .accessibilityHidden(true)
        .task(id: url) {
            image = nil
            failed = false
            guard let url else { failed = true; return }
            let bytes = await ThumbnailCache.shared.load(url)
            guard !Task.isCancelled else { return }
            image = bytes.flatMap(NSImage.init(data:))
            failed = image == nil
        }
    }
}

private actor ThumbnailCache {
    static let shared = ThumbnailCache()
    private var cache: [URL: Data] = [:]
    private var order: [URL] = []

    func load(_ url: URL) -> Data? {
        if let cached = cache[url] { return cached }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 640,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        let bytes = data as Data
        cache[url] = bytes
        order.append(url)
        if order.count > 100 { cache.removeValue(forKey: order.removeFirst()) }
        return bytes
    }
}
