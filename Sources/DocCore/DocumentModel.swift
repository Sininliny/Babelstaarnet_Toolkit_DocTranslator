import CoreGraphics
import Foundation

/// What was dropped on the window.
public struct DocumentSource: Sendable, Identifiable {
    public enum Kind: String, Sendable {
        case pdf
        case image

        public var displayName: String {
            switch self {
            case .pdf: return "PDF"
            case .image: return "Image"
            }
        }
    }

    public let id: UUID
    public let url: URL
    public let kind: Kind
    public let pageCount: Int

    public init(id: UUID = UUID(), url: URL, kind: Kind, pageCount: Int) {
        self.id = id
        self.url = url
        self.kind = kind
        self.pageCount = pageCount
    }

    public var displayName: String { url.lastPathComponent }
}

/// One page, rasterized once and read by everything.
///
/// Rendered a single time and shared, because the two readers must be looking
/// at the same pixels for their disagreement to mean anything. If Vision saw a
/// 300 dpi render and the vision model saw a 96 dpi one, a difference between
/// them would be a fact about the renderer.
public struct PageImage: @unchecked Sendable, Identifiable {
    public let id: UUID
    public let index: Int
    public let image: CGImage
    /// The page's size in PDF points, so a box can be mapped back onto the
    /// original page rather than onto the raster.
    public let pointSize: CGSize

    public init(
        id: UUID = UUID(),
        index: Int,
        image: CGImage,
        pointSize: CGSize
    ) {
        self.id = id
        self.index = index
        self.image = image
        self.pointSize = pointSize
    }

    public var pixelSize: CGSize {
        CGSize(width: image.width, height: image.height)
    }
}

/// A rectangle on a page, normalized to 0...1 with the origin at the top left.
///
/// Top left rather than Vision's bottom left: every other coordinate system
/// this app touches — PDFKit's crop box aside, SwiftUI, AppKit drawing, the
/// HTML export — puts the origin at the top, so the conversion happens once,
/// where Vision's results are read, instead of at every use.
public struct BlockBox: Sendable, Hashable, Codable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var minX: Double { x }
    public var minY: Double { y }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var midY: Double { y + height / 2 }

    public func union(_ other: BlockBox) -> BlockBox {
        let minX = Swift.min(self.minX, other.minX)
        let minY = Swift.min(self.minY, other.minY)
        return BlockBox(
            x: minX,
            y: minY,
            width: Swift.max(self.maxX, other.maxX) - minX,
            height: Swift.max(self.maxY, other.maxY) - minY
        )
    }

    /// How much of the narrower box's width the two share, which is what
    /// decides whether two lines belong to the same column.
    public func horizontalOverlap(with other: BlockBox) -> Double {
        let overlap = Swift.min(maxX, other.maxX) - Swift.max(minX, other.minX)
        let narrower = Swift.min(width, other.width)
        guard narrower > 0 else { return 0 }
        return Swift.max(0, overlap) / narrower
    }

    public static let full = BlockBox(x: 0, y: 0, width: 1, height: 1)
}

/// What a block of text is for, which decides how it is rendered and how
/// literally it is translated.
public enum BlockKind: String, Sendable, Codable, CaseIterable {
    case heading
    case paragraph
    case listItem
    case tableRow
    case caption
    case pageFurniture

    /// Page numbers and running heads are read, kept, and never sent to a
    /// model: translating "第 3 页" costs a model call to produce "Page 3".
    public var isTranslatable: Bool {
        self != .pageFurniture
    }
}

/// A block of source text as one reader saw it.
public struct SourceBlock: Sendable, Identifiable {
    public let id: UUID
    public let pageIndex: Int
    /// Position in reading order on its page.
    public let order: Int
    public let box: BlockBox
    public let kind: BlockKind
    /// The lines it was assembled from, kept so a disagreement can be shown
    /// at the line it actually happened on.
    public let lines: [String]
    public let text: String
    /// What the reader thought of its own reading, where it says. Vision
    /// reports one; a vision model does not.
    public let confidence: Double?

    public init(
        id: UUID = UUID(),
        pageIndex: Int,
        order: Int,
        box: BlockBox,
        kind: BlockKind,
        lines: [String],
        text: String,
        confidence: Double? = nil
    ) {
        self.id = id
        self.pageIndex = pageIndex
        self.order = order
        self.box = box
        self.kind = kind
        self.lines = lines
        self.text = text
        self.confidence = confidence
    }
}

/// Which of the readers produced a transcription.
public enum PageReader: String, Sendable, Codable, CaseIterable {
    /// Text the PDF itself carries. Not OCR at all, and right by construction
    /// where it exists.
    case pdfTextLayer
    /// Apple Vision, on-device, accurate level.
    case visionOCR
    /// A local vision-language model looking at the same page image.
    case visionLanguageModel

    public var displayName: String {
        switch self {
        case .pdfTextLayer: return "PDF text layer"
        case .visionOCR: return "Vision OCR"
        case .visionLanguageModel: return "Vision model"
        }
    }

    /// The text layer is the page's own copy of its text, so where it exists
    /// it settles a disagreement without a model being asked.
    public var isAuthoritative: Bool { self == .pdfTextLayer }

    /// Whether this reader is cheap enough to run over pages the app only
    /// wants the gist of. Vision is half a second a page and a vision model
    /// is closer to twenty, so the survey that establishes what a document is
    /// can afford the first and cannot afford the second — a survey that
    /// costs a minute has stopped being a survey.
    public var readsQuickly: Bool { self != .visionLanguageModel }
}

/// One reader's account of one page.
public struct PageReading: Sendable {
    public let reader: PageReader
    public let pageIndex: Int
    public let blocks: [SourceBlock]
    public let seconds: Double

    public init(
        reader: PageReader,
        pageIndex: Int,
        blocks: [SourceBlock],
        seconds: Double = 0
    ) {
        self.reader = reader
        self.pageIndex = pageIndex
        self.blocks = blocks
        self.seconds = seconds
    }

    public var text: String {
        blocks.map(\.text).joined(separator: "\n")
    }

    public var isEmpty: Bool {
        blocks.allSatisfy { $0.text.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty }
    }
}

/// Anything that can read a page. The pipeline is written against this rather
/// than against Vision or a model client, which is what lets the whole
/// agent chain run against fixtures in a check with no GPU and no server.
public protocol PageTranscriber: Sendable {
    var reader: PageReader { get }
    func transcribe(
        _ page: PageImage,
        language: SourceLanguage
    ) async throws -> PageReading
}
