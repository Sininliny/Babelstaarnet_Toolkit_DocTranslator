import CoreGraphics
import DocCore
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

public enum IngestFailure: LocalizedError {
    case unreadable(URL)
    case unsupportedType(String)
    case noPages(URL)
    case pageOutOfRange(Int)
    case couldNotRender(Int)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let url):
            return "\(url.lastPathComponent) could not be opened."
        case .unsupportedType(let type):
            return "\(type) is not a kind of file Læsesalen reads."
        case .noPages(let url):
            return "\(url.lastPathComponent) has no pages."
        case .pageOutOfRange(let index):
            return "There is no page \(index + 1)."
        case .couldNotRender(let index):
            return "Page \(index + 1) could not be drawn."
        }
    }
}

public enum DocumentLoader {
    /// What the app will open. Deliberately short: a translator that accepts
    /// every format accepts formats it reads badly.
    public static let readableTypes: [UTType] = [.pdf, .png, .jpeg]

    public static func open(_ url: URL) throws -> any PageProvider {
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?
            .contentType
        switch type {
        case .some(let type) where type.conforms(to: .pdf):
            return try PDFPageProvider(url: url)
        case .some(let type) where type.conforms(to: .image):
            return try ImagePageProvider(url: url)
        case .some(let type):
            throw IngestFailure.unsupportedType(
                type.localizedDescription ?? type.identifier
            )
        case nil:
            throw IngestFailure.unreadable(url)
        }
    }
}

/// How large a page is drawn.
///
/// Chinese sets the floor here. A hanzi is a dense glyph — a dozen strokes in
/// the space a Latin letter uses for two — so a resolution that reads English
/// comfortably turns 田 and 由 into the same smudge. 300 dpi is the number
/// scanners settled on for CJK for the same reason, and the pixel ceiling
/// exists so an A0 poster does not turn into a 400-megapixel bitmap on its
/// way to the same answer.
public struct RenderSize: Sendable {
    public let targetDPI: Double
    public let maximumPixels: Int

    public init(targetDPI: Double = 300, maximumPixels: Int = 40_000_000) {
        self.targetDPI = targetDPI
        self.maximumPixels = maximumPixels
    }

    public static let forReading = RenderSize()

    func scale(forPointSize size: CGSize) -> Double {
        let scale = targetDPI / 72
        let pixels = Double(size.width * size.height) * scale * scale
        guard pixels > Double(maximumPixels) else { return scale }
        return scale * (Double(maximumPixels) / pixels).squareRoot()
    }
}

/// A PDF: rendered for the recognizers, and mined for the text it already has.
public final class PDFPageProvider: PageProvider, @unchecked Sendable {
    public let source: DocumentSource
    private let document: PDFDocument
    private let renderSize: RenderSize
    /// PDFKit is not thread-safe and the pipeline reads pages from a task
    /// group, so every touch of the document is serialized here rather than
    /// left to luck.
    private let lock = NSLock()

    public init(url: URL, renderSize: RenderSize = .forReading) throws {
        guard let document = PDFDocument(url: url) else {
            throw IngestFailure.unreadable(url)
        }
        guard document.pageCount > 0 else {
            throw IngestFailure.noPages(url)
        }
        self.document = document
        self.renderSize = renderSize
        self.source = DocumentSource(
            url: url,
            kind: .pdf,
            pageCount: document.pageCount
        )
    }

    public func page(at index: Int) throws -> PageImage {
        lock.lock()
        defer { lock.unlock() }
        guard let page = document.page(at: index) else {
            throw IngestFailure.pageOutOfRange(index)
        }
        let bounds = page.bounds(for: .cropBox)
        let scale = renderSize.scale(forPointSize: bounds.size)
        let width = Int((bounds.width * scale).rounded())
        let height = Int((bounds.height * scale).rounded())

        guard width > 0, height > 0, let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            throw IngestFailure.couldNotRender(index)
        }

        // A PDF page has no background of its own. Drawn onto the context's
        // zeroed memory that is white text on black, which recognizes as
        // nothing at all.
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -bounds.origin.x, y: -bounds.origin.y)
        page.draw(with: .cropBox, to: context)

        guard let image = context.makeImage() else {
            throw IngestFailure.couldNotRender(index)
        }
        return PageImage(index: index, image: image, pointSize: bounds.size)
    }

    public func textLayer(at index: Int) -> PageReading? {
        lock.lock()
        defer { lock.unlock() }
        guard let page = document.page(at: index) else { return nil }
        return PDFTextLayer.reading(from: page, pageIndex: index)
    }
}

/// A single image. One page, no text layer, nothing to mine.
public final class ImagePageProvider: PageProvider, @unchecked Sendable {
    public let source: DocumentSource
    private let image: CGImage

    public init(url: URL) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(
                source,
                0,
                [kCGImageSourceShouldCache: false] as CFDictionary
              ) else {
            throw IngestFailure.unreadable(url)
        }
        self.image = image
        self.source = DocumentSource(url: url, kind: .image, pageCount: 1)
    }

    public func page(at index: Int) throws -> PageImage {
        guard index == 0 else { throw IngestFailure.pageOutOfRange(index) }
        return PageImage(
            index: 0,
            image: image,
            pointSize: CGSize(width: image.width, height: image.height)
        )
    }

    public func textLayer(at index: Int) -> PageReading? { nil }
}
