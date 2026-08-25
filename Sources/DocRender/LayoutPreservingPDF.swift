import AppKit
import CoreGraphics
import CoreText
import DocCore
import Foundation

/// The document again, looking like itself, in English.
///
/// This is the output most people picture when they ask for a document to be
/// translated: the same form, the same table, the same letterhead and the
/// same red seal, with the words they could not read now in words they can.
/// It is also the output that can lie most convincingly, so two rules hold it
/// down:
///
/// **Only text with a place on the page is replaced.** A block the character
/// recognizer found has a box, measured on the page. A block that only the
/// vision-language model reported has no geometry at all, and painting it
/// somewhere plausible would put a sentence on the page that nothing measured
/// — so those blocks are left out of this export entirely and stay in the
/// side-by-side one, where they are visible as what they are.
///
/// **Everything not replaced is left exactly as it was.** Page numbers,
/// stamps, signatures, photographs, logos, rules, and anything the readers
/// did not agree was text: untouched pixels. The English is drawn over a
/// patch the size of the original text and nothing wider.
public enum LayoutPreservingPDF {
    public enum Failure: LocalizedError {
        case couldNotStartPDF
        case noPages

        public var errorDescription: String? {
            switch self {
            case .couldNotStartPDF:
                return "The translated PDF could not be started."
            case .noPages:
                return "There were no pages to write."
            }
        }
    }

    /// How much larger than the measured box the erased patch is, as a share
    /// of the box's height. Recognizers report a tight box around the glyphs
    /// and antialiasing puts a grey fringe just outside it, which reads as a
    /// shadow of the original text under the English.
    static let bleed = 0.12
    /// Below this the English is unreadable, so it is allowed to run past the
    /// bottom of the original box rather than shrink further. A translation
    /// that overflows can be read; one set at three points cannot.
    static let minimumTextSize: CGFloat = 6.5
    /// CoreText's frame-size suggestion is asked for an unbounded height, and
    /// "unbounded" has to be a large finite number. Given
    /// `.greatestFiniteMagnitude` it returns the height of a single line, so
    /// every block appears to fit at any size and nothing is ever shrunk —
    /// which looks exactly like a fitting algorithm that does not work.
    static let unbounded: CGFloat = 1_000_000

    public static func render(
        _ document: TranslatedDocument,
        pages provider: any PageProvider
    ) throws -> Data {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data) else {
            throw Failure.couldNotStartPDF
        }
        guard !document.pages.isEmpty else { throw Failure.noPages }

        var firstBox = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let context = CGContext(
            consumer: consumer,
            mediaBox: &firstBox,
            [
                kCGPDFContextTitle as String:
                    document.source.displayName + " (English)",
                kCGPDFContextCreator as String: "Læsesalen"
            ] as CFDictionary
        ) else {
            throw Failure.couldNotStartPDF
        }

        for page in document.pages {
            guard let image = try? provider.page(at: page.index) else {
                continue
            }
            // The page's own size, so the translated PDF prints on the same
            // paper as the original.
            let size = image.pointSize.width > 0 && image.pointSize.height > 0
                ? image.pointSize
                : image.pixelSize
            var box = CGRect(origin: .zero, size: size)
            context.beginPage(mediaBox: &box)
            context.draw(image.image, in: box)

            for block in page.blocks {
                draw(block, on: image, in: box, into: context)
            }
            context.endPage()
        }

        context.closePDF()
        return data as Data
    }

    private static func draw(
        _ block: TranslatedBlock,
        on page: PageImage,
        in box: CGRect,
        into context: CGContext
    ) {
        let english = block.text.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !english.isEmpty else { return }
        // Untranslated by design — a page number, or a block the translator
        // handed back unchanged. Its original pixels are already right.
        guard english != block.source.text else { return }
        // No geometry: see the note at the top of this file.
        guard block.source.box != .full else { return }

        let frame = rect(for: block.source.box, in: box)
        guard frame.width > 4, frame.height > 4 else { return }

        let colours = PageColours.sample(
            page.image,
            box: pixelRect(for: block.source.box, in: page)
        )

        let patch = frame.insetBy(
            dx: -frame.height * bleed,
            dy: -frame.height * bleed
        ).intersection(box)
        context.setFillColor(colours.background)
        context.fill(patch)

        let attributed = attributedText(
            english,
            block: block,
            colour: colours.ink,
            within: frame.size
        )
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let path = CGPath(rect: frame, transform: nil)
        // A frame clipped to the box would silently drop the end of a
        // sentence, which is the one thing a translation must never do. The
        // fitting above shrinks the type until it fits; if even the floor
        // does not fit, the frame is grown downward instead, so the text
        // overruns visibly rather than vanishing.
        let fitted = CTFramesetterCreateFrame(
            framesetter,
            CFRangeMake(0, 0),
            grownIfNeeded(path, framesetter: framesetter, frame: frame, in: box),
            nil
        )
        CTFrameDraw(fitted, context)
    }

    /// The English, set to fit the space the Chinese occupied.
    private static func attributedText(
        _ text: String,
        block: TranslatedBlock,
        colour: CGColor,
        within size: CGSize
    ) -> NSAttributedString {
        // Start from a size that should nearly fit, then shrink until it
        // does. The estimate is the usual one for Latin text — a character
        // occupies about half a square em — and it matters only for speed:
        // starting at the box's full height would be correct too, and would
        // spend thirty shrink steps getting down to a paragraph.
        //
        // Shrinking is the normal case, not the exception. English set in a
        // Latin face is longer than the Chinese it came from, and the space
        // available was measured for the Chinese.
        let characters = CGFloat(max(1, text.count))
        let estimate = (size.width * size.height / (0.52 * characters))
            .squareRoot()
        // Never larger than the type it replaces. Without this cap, a short
        // block with a roomy box gets a bigger face than the paragraph beside
        // it and the page comes out in four different type sizes — each block
        // correct on its own and the document wrong as a whole.
        let originalLine = size.height / CGFloat(block.source.lineCount)
        var pointSize = min(72, max(
            minimumTextSize,
            min(originalLine * 1.05, estimate * 1.25)
        ))
        var best = attributed(
            text,
            block: block,
            size: pointSize,
            colour: colour
        )
        while pointSize > minimumTextSize {
            let framesetter = CTFramesetterCreateWithAttributedString(best)
            let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
                framesetter,
                CFRangeMake(0, 0),
                nil,
                CGSize(width: size.width, height: unbounded),
                nil
            )
            if suggested.height <= size.height { break }
            pointSize = max(minimumTextSize, pointSize - max(0.5, pointSize * 0.08))
            best = attributed(
                text,
                block: block,
                size: pointSize,
                colour: colour
            )
        }
        return best
    }

    private static func attributed(
        _ text: String,
        block: TranslatedBlock,
        size: CGFloat,
        colour: CGColor
    ) -> NSAttributedString {
        let weight: CTFontSymbolicTraits = block.source.kind == .heading
            ? .traitBold
            : []
        var font = CTFontCreateWithName(
            "HelveticaNeue" as CFString,
            size,
            nil
        )
        if weight.contains(.traitBold),
           let bold = CTFontCreateCopyWithSymbolicTraits(
            font,
            size,
            nil,
            .traitBold,
            .traitBold
           ) {
            font = bold
        }

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment(for: block)
        paragraph.lineBreakMode = .byWordWrapping
        // Slightly tight: the English has to live in a space that was
        // measured for something denser.
        paragraph.lineHeightMultiple = 0.95

        return NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: colour,
                .paragraphStyle: paragraph
            ]
        )
    }

    /// Centred text stays centred. A title that was in the middle of a
    /// letterhead and comes back flush left looks like a different document.
    private static func alignment(for block: TranslatedBlock) -> NSTextAlignment {
        let box = block.source.box
        let centre = box.x + box.width / 2
        let looksCentred = abs(centre - 0.5) < 0.06 && box.width < 0.8
        return looksCentred ? .center : .left
    }

    private static func grownIfNeeded(
        _ path: CGPath,
        framesetter: CTFramesetter,
        frame: CGRect,
        in box: CGRect
    ) -> CGPath {
        let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRangeMake(0, 0),
            nil,
            CGSize(width: frame.width, height: unbounded),
            nil
        )
        guard suggested.height > frame.height else { return path }
        let grown = CGRect(
            x: frame.minX,
            y: max(box.minY, frame.maxY - suggested.height),
            width: frame.width,
            height: min(suggested.height, frame.maxY - box.minY)
        )
        return CGPath(rect: grown, transform: nil)
    }

    /// Normalized, origin top left — to PDF points, origin bottom left.
    public static func rect(for block: BlockBox, in box: CGRect) -> CGRect {
        CGRect(
            x: box.minX + CGFloat(block.x) * box.width,
            y: box.minY + CGFloat(1 - block.maxY) * box.height,
            width: CGFloat(block.width) * box.width,
            height: CGFloat(block.height) * box.height
        )
    }

    /// Normalized to pixels in the page image, whose origin is at the top
    /// left — so, unlike the PDF rect, no flip.
    public static func pixelRect(for block: BlockBox, in page: PageImage) -> CGRect {
        CGRect(
            x: CGFloat(block.x) * CGFloat(page.image.width),
            y: CGFloat(block.y) * CGFloat(page.image.height),
            width: CGFloat(block.width) * CGFloat(page.image.width),
            height: CGFloat(block.height) * CGFloat(page.image.height)
        )
    }
}
