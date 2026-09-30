import AppKit
import CryptoKit
import Foundation
import ImageIO
import PDFKit
import Vision

public enum ProjectDocumentImporterError: Error, LocalizedError, Equatable, Sendable {
    case unsupportedFileType(String)
    case unreadableFile(String)
    case invalidPDF(String)
    case invalidImage(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedFileType(let name): "Unsupported document type: \(name). Choose a PDF, Markdown, or image file."
        case .unreadableFile(let name): "The source file could not be read: \(name)."
        case .invalidPDF(let detail): "The PDF could not be read: \(detail)"
        case .invalidImage(let detail): "The image could not be read: \(detail)"
        }
    }
}

/// The result of inspecting a source before it is assigned a project-owned ID and revision.
/// The store owns persistence and copies the returned data into the library.
public struct ProjectDocumentImportArtifact: Sendable {
    public struct AssetPayload: Sendable {
        public let sourcePath: String
        public let data: Data?
        public let suggestedFilename: String

        public init(sourcePath: String, data: Data?, suggestedFilename: String) {
            self.sourcePath = sourcePath; self.data = data; self.suggestedFilename = suggestedFilename
        }
    }

    public let sourceURL: URL
    public let sourceKey: String
    public let name: String
    public let kind: ProjectDocumentSourceKind
    public let originalData: Data
    public let contentHash: String
    public let units: [ProjectDocumentExtractionUnit]
    public let assets: [ProjectDocumentAsset]
    public let assetPayloads: [AssetPayload]
    public let errors: [ProjectDocumentImportError]
    public let status: ProjectDocumentSourceStatus

    public init(
        sourceURL: URL,
        sourceKey: String,
        name: String,
        kind: ProjectDocumentSourceKind,
        originalData: Data,
        contentHash: String,
        units: [ProjectDocumentExtractionUnit],
        assets: [ProjectDocumentAsset],
        assetPayloads: [AssetPayload] = [],
        errors: [ProjectDocumentImportError] = [],
        status: ProjectDocumentSourceStatus
    ) {
        self.sourceURL = sourceURL; self.sourceKey = sourceKey; self.name = name; self.kind = kind; self.originalData = originalData
        self.contentHash = contentHash; self.units = units; self.assets = assets; self.assetPayloads = assetPayloads; self.errors = errors; self.status = status
    }
}

public enum DocumentSourceImporter {
    public static let extractionVersion = "1"

    public static func inspect(_ url: URL, selectedAttachments: [URL] = [], checkpointURL: URL? = nil, sourceKeyOverride: String? = nil) throws -> ProjectDocumentImportArtifact {
        let standardized = url.standardizedFileURL
        guard FileManager.default.isReadableFile(atPath: standardized.path) else {
            throw ProjectDocumentImporterError.unreadableFile(url.lastPathComponent)
        }
        let data: Data
        do { data = try Data(contentsOf: standardized) } catch { throw ProjectDocumentImporterError.unreadableFile(url.lastPathComponent) }
        let kind = try sourceKind(for: standardized)
        let hash = sha256(data)
        let artifact: ProjectDocumentImportArtifact
        switch kind {
        case .markdown:
            artifact = parseMarkdown(url: standardized, data: data, hash: hash, selectedAttachments: selectedAttachments)
        case .pdf: artifact = try parsePDF(url: standardized, data: data, hash: hash, checkpointURL: checkpointURL)
        case .image: artifact = parseImage(url: standardized, data: data, hash: hash)
        }
        // A Markdown source includes its selected local attachments in its
        // identity. Importing the same file again after selecting a newly
        // available image must create a revision so the resolved evidence is
        // retained. The original file hash remains the first component.
        let contentHash = kind == .markdown ? markdownContentHash(base: hash, assets: artifact.assets) : artifact.contentHash
        let normalized: ProjectDocumentImportArtifact
        if contentHash == artifact.contentHash {
            normalized = artifact
        } else {
            normalized = .init(sourceURL: artifact.sourceURL, sourceKey: artifact.sourceKey, name: artifact.name, kind: artifact.kind,
                               originalData: artifact.originalData, contentHash: contentHash, units: artifact.units,
                               assets: artifact.assets, assetPayloads: artifact.assetPayloads, errors: artifact.errors, status: artifact.status)
        }
        guard let sourceKeyOverride, sourceKeyOverride != normalized.sourceKey else { return normalized }
        return .init(sourceURL: normalized.sourceURL, sourceKey: sourceKeyOverride, name: normalized.name, kind: normalized.kind,
                     originalData: normalized.originalData, contentHash: normalized.contentHash, units: normalized.units,
                     assets: normalized.assets, assetPayloads: normalized.assetPayloads, errors: normalized.errors, status: normalized.status)
    }

    public static func sourceKind(for url: URL) throws -> ProjectDocumentSourceKind {
        switch url.pathExtension.lowercased() {
        case "md", "markdown", "mdown", "mkdn": return .markdown
        case "pdf": return .pdf
        case "png", "jpg", "jpeg", "webp", "heic", "tif", "tiff": return .image
        default: throw ProjectDocumentImporterError.unsupportedFileType(url.lastPathComponent)
        }
    }

    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func markdownContentHash(base: String, assets: [ProjectDocumentAsset]) -> String {
        guard !assets.isEmpty else { return base }
        let descriptor = assets.sorted { $0.sourcePath < $1.sourcePath }.map { asset in
            [asset.sourcePath, asset.contentHash ?? "", asset.status.rawValue, asset.error ?? ""].joined(separator: "|")
        }.joined(separator: "\n")
        return sha256(Data((base + "\n" + descriptor).utf8))
    }

    private static func parseMarkdown(url: URL, data: Data, hash: String, selectedAttachments: [URL]) -> ProjectDocumentImportArtifact {
        guard let markdown = String(data: data, encoding: .utf8) else {
            return .init(
                sourceURL: url,
                sourceKey: url.path,
                name: url.lastPathComponent,
                kind: .markdown,
                originalData: data,
                contentHash: hash,
                units: [],
                assets: [],
                errors: [.init(message: "The Markdown source is not valid UTF-8 and could not be extracted.", isFatal: true)],
                status: .failed
            )
        }
        let lines = markdown.components(separatedBy: .newlines)
        var units: [ProjectDocumentExtractionUnit] = []
        var assets: [ProjectDocumentAsset] = []
        var payloads: [ProjectDocumentImportArtifact.AssetPayload] = []
        var errors: [ProjectDocumentImportError] = []
        var codeLines: [String] = []
        var codeStart = 0
        var inCode = false
        var ordinal = 0
        let allowedAttachments = Set(selectedAttachments.map { $0.resolvingSymlinksInPath().standardizedFileURL.path })

        func addUnit(_ unit: ProjectDocumentExtractionUnit) {
            units.append(unit); ordinal += 1
        }

        for (index, line) in lines.enumerated() {
            let lineNumber = index + 1
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                if inCode {
                    let locator = ProjectDocumentLocator(markdownLine: codeStart, endLine: lineNumber)
                    addUnit(.init(ordinal: ordinal, kind: .code, locator: locator, text: codeLines.joined(separator: "\n")))
                    codeLines.removeAll(); inCode = false
                } else {
                    codeStart = lineNumber; inCode = true
                }
                continue
            }
            if inCode {
                codeLines.append(line)
                continue
            }
            guard !trimmed.isEmpty else { continue }
            if let heading = markdownHeading(trimmed) {
                addUnit(.init(ordinal: ordinal, kind: .heading, locator: .init(markdownLine: lineNumber), title: heading, text: line))
            } else {
                let kind: ProjectDocumentUnitKind
                if trimmed.range(of: #"^([-*+]\s|\d+[.)]\s)"#, options: .regularExpression) != nil { kind = .list }
                else if trimmed.hasPrefix("|") { kind = .table }
                else if trimmed.range(of: #"!\[[^\]]*\]\([^)]*\)"#, options: .regularExpression) != nil { kind = .image }
                else { kind = .paragraph }
                addUnit(.init(ordinal: ordinal, kind: kind, locator: .init(markdownLine: lineNumber), text: line))
            }

            for path in markdownAssetPaths(in: line) {
                guard !assets.contains(where: { $0.sourcePath == path }) else { continue }
                if let remoteURL = URL(string: path), remoteURL.scheme != nil {
                    assets.append(.init(sourcePath: path, contentHash: nil, status: .external))
                    continue
                }
                let decodedPath = path.removingPercentEncoding ?? path
                let base = url.deletingLastPathComponent().standardizedFileURL
                let candidate = base.appending(path: decodedPath).standardizedFileURL
                let resolvedCandidate = candidate.resolvingSymlinksInPath().standardizedFileURL
                guard resolvedCandidate.path.hasPrefix(base.resolvingSymlinksInPath().standardizedFileURL.path + "/"),
                      allowedAttachments.contains(resolvedCandidate.path),
                      FileManager.default.isReadableFile(atPath: resolvedCandidate.path) else {
                    let message = allowedAttachments.contains(resolvedCandidate.path)
                        ? "Local Markdown asset was not found: \(path)."
                        : "Local Markdown asset was not selected for import: \(path)."
                    assets.append(.init(sourcePath: path, contentHash: nil, status: .missing, error: message))
                    errors.append(.init(locator: .init(asset: path), message: message))
                    continue
                }
                do {
                    let assetData = try Data(contentsOf: resolvedCandidate)
                    assets.append(.init(sourcePath: path, contentHash: sha256(assetData), status: .copied))
                    payloads.append(.init(sourcePath: path, data: assetData, suggestedFilename: resolvedCandidate.lastPathComponent))
                } catch {
                    assets.append(.init(sourcePath: path, contentHash: nil, status: .failed, error: error.localizedDescription))
                    errors.append(.init(locator: .init(asset: path), message: "Could not read Markdown asset \(path): \(error.localizedDescription)."))
                }
            }
        }
        if inCode {
            let locator = ProjectDocumentLocator(markdownLine: codeStart, endLine: max(codeStart, lines.count))
            addUnit(.init(ordinal: ordinal, kind: .code, locator: locator, text: codeLines.joined(separator: "\n")))
            errors.append(.init(locator: locator, message: "Markdown code fence was not closed; the remaining lines were retained as code."))
        }
        return .init(sourceURL: url, sourceKey: url.path, name: url.lastPathComponent, kind: .markdown, originalData: data, contentHash: hash,
                     units: units, assets: assets, assetPayloads: payloads, errors: errors,
                     status: errors.contains(where: \ProjectDocumentImportError.isFatal) ? .failed : errors.isEmpty ? .ready : .partial)
    }

    private struct PDFCheckpoint: Codable {
        let contentHash: String
        let pageCount: Int
        let completedPages: Int
        let units: [ProjectDocumentExtractionUnit]
        let assets: [ProjectDocumentAsset]
        let payloads: [CheckpointPayload]
        let errors: [ProjectDocumentImportError]

        struct CheckpointPayload: Codable {
            let sourcePath: String
            let data: Data
            let suggestedFilename: String
        }
    }

    private static func parsePDF(url: URL, data: Data, hash: String, checkpointURL: URL? = nil) throws -> ProjectDocumentImportArtifact {
        guard let document = PDFDocument(data: data) else {
            return .init(sourceURL: url, sourceKey: url.path, name: url.lastPathComponent, kind: .pdf, originalData: data, contentHash: hash,
                         units: [], assets: [], errors: [.init(message: "The PDF is damaged, encrypted, or otherwise unreadable.", isFatal: true)], status: .failed)
        }
        if document.isLocked {
            return .init(sourceURL: url, sourceKey: url.path, name: url.lastPathComponent, kind: .pdf, originalData: data, contentHash: hash,
                         units: [], assets: [], errors: [.init(message: "The PDF is locked and its pages could not be extracted.", isFatal: true)], status: .failed)
        }
        var units: [ProjectDocumentExtractionUnit] = []
        var assets: [ProjectDocumentAsset] = []
        var payloads: [ProjectDocumentImportArtifact.AssetPayload] = []
        var errors: [ProjectDocumentImportError] = []
        var startPage = 0
        if let checkpointURL,
           let checkpointData = try? Data(contentsOf: checkpointURL),
           let checkpoint = try? JSONDecoder().decode(PDFCheckpoint.self, from: checkpointData),
           checkpoint.contentHash == hash, checkpoint.pageCount == document.pageCount,
           checkpoint.completedPages <= document.pageCount {
            startPage = checkpoint.completedPages
            units = checkpoint.units
            assets = checkpoint.assets
            payloads = checkpoint.payloads.map { .init(sourcePath: $0.sourcePath, data: $0.data, suggestedFilename: $0.suggestedFilename) }
            errors = checkpoint.errors
        }
        for pageIndex in startPage..<document.pageCount {
            try Task.checkCancellation()
            let pageNumber = pageIndex + 1
            let page = document.page(at: pageIndex)
            let imageData = page.flatMap(renderPNG)
            var text = page?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if text.isEmpty, let imageData, let cgImage = cgImage(from: imageData) {
                text = recognizeText(in: cgImage)
            }
            let locator = ProjectDocumentLocator(pdfPage: pageNumber)
            units.append(.init(ordinal: pageIndex, kind: .page, locator: locator, title: "Page \(pageNumber)", text: text))
            let filename = "page-\(pageNumber).png"
            if let imageData {
                assets.append(.init(sourcePath: filename, contentHash: sha256(imageData), status: .copied))
                payloads.append(.init(sourcePath: filename, data: imageData, suggestedFilename: filename))
            } else {
                assets.append(.init(sourcePath: filename, contentHash: nil, status: .failed, error: "Page could not be rendered."))
                errors.append(.init(locator: locator, message: "Page \(pageNumber) could not be rendered."))
            }
            if text.isEmpty {
                errors.append(.init(locator: locator, message: "No selectable text or OCR text was found on page \(pageNumber)."))
            }
            if let checkpointURL {
                let checkpoint = PDFCheckpoint(contentHash: hash, pageCount: document.pageCount, completedPages: pageNumber,
                    units: units, assets: assets,
                    payloads: payloads.compactMap { payload in
                        guard let data = payload.data else { return nil }
                        return .init(sourcePath: payload.sourcePath, data: data, suggestedFilename: payload.suggestedFilename)
                    }, errors: errors)
                try FileManager.default.createDirectory(at: checkpointURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                let encoded = try JSONEncoder().encode(checkpoint)
                try encoded.write(to: checkpointURL, options: .atomic)
            }
        }
        return .init(sourceURL: url, sourceKey: url.path, name: url.lastPathComponent, kind: .pdf, originalData: data, contentHash: hash,
                     units: units, assets: assets, assetPayloads: payloads, errors: errors,
                     status: errors.isEmpty ? .ready : .partial)
    }

    private static func parseImage(url: URL, data: Data, hash: String) -> ProjectDocumentImportArtifact {
        guard let cgImage = cgImage(from: data) else {
            return .init(sourceURL: url, sourceKey: url.path, name: url.lastPathComponent, kind: .image, originalData: data, contentHash: hash,
                         units: [], assets: [], errors: [.init(message: "The image format is unsupported or damaged.", isFatal: true)], status: .failed)
        }
        let text = recognizeText(in: cgImage)
        let locator = ProjectDocumentLocator(asset: url.lastPathComponent)
        let unit = ProjectDocumentExtractionUnit(ordinal: 0, kind: .image, locator: locator, title: url.lastPathComponent, text: text)
        let asset = ProjectDocumentAsset(sourcePath: url.lastPathComponent, contentHash: hash, status: .copied)
        return .init(sourceURL: url, sourceKey: url.path, name: url.lastPathComponent, kind: .image, originalData: data, contentHash: hash,
                     units: [unit], assets: [asset], assetPayloads: [.init(sourcePath: url.lastPathComponent, data: data, suggestedFilename: url.lastPathComponent)], status: .ready)
    }

    private static func markdownHeading(_ line: String) -> String? {
        guard let match = line.range(of: #"^#{1,6}\s+(.+?)\s*$"#, options: .regularExpression) else { return nil }
        let value = String(line[match])
        return value.replacingOccurrences(of: #"^#{1,6}\s+"#, with: "", options: .regularExpression)
    }

    private static func markdownAssetPaths(in line: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: #"!\[[^\]]*\]\(([^)\s]+)(?:\s+[^)]*)?\)"#) else { return [] }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        return expression.matches(in: line, range: range).compactMap {
            guard $0.numberOfRanges > 1, let valueRange = Range($0.range(at: 1), in: line) else { return nil }
            return String(line[valueRange])
        }
    }

    private static func cgImage(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private static func renderPNG(_ page: PDFPage) -> Data? {
        let bounds = page.bounds(for: .mediaBox)
        let scale = min(2.0, max(0.75, 1800.0 / max(bounds.width, 1)))
        let width = max(1, Int(bounds.width * scale))
        let height = max(1, Int(bounds.height * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.saveGState()
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        page.draw(with: .mediaBox, to: context)
        context.restoreGState()
        guard let image = context.makeImage() else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    private static func recognizeText(in image: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do { try handler.perform([request]) } catch { return "" }
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
}
