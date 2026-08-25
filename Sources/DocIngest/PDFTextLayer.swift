import CoreGraphics
import DocCore
import Foundation
import PDFKit

/// The text a PDF already carries, recovered with its layout.
///
/// This is the closest thing the pipeline has to ground truth, and it is free:
/// a born-digital PDF — anything exported from Word, InDesign, LaTeX, or a
/// government form generator — contains the exact characters that were typeset,
/// with no recognition involved. Where it exists, the double-check is not two
/// guesses being compared but two guesses being *graded*.
///
/// It is not always right about *order*: a PDF's text is stored in the order
/// the producer emitted it, which for a two-column layout is often not reading
/// order. So the characters are taken with their positions and re-assembled by
/// the same layout code that assembles OCR lines, rather than trusting
/// `page.string`.
public enum PDFTextLayer {
    /// How much of a page must carry text before the layer is treated as
    /// real. A scanned PDF often has a handful of characters on it — a
    /// stamped page number, an OCR watermark from whatever produced it — and
    /// those must not be mistaken for the page's text.
    static let minimumCharacters = 24

    public static func reading(
        from page: PDFPage,
        pageIndex: Int
    ) -> PageReading? {
        let count = page.numberOfCharacters
        guard count >= minimumCharacters else { return nil }
        guard let string = page.string, !string.isEmpty else { return nil }

        let characters = Array(string)
        // PDFKit indexes characters and the string separately, and on a page
        // with surrogate pairs or an unusual encoding the two can disagree.
        // Rather than mis-place every box after the first mismatch, the layer
        // is abandoned and OCR reads the page like any other.
        guard characters.count == count else { return nil }

        let bounds = page.bounds(for: .cropBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }

        var lines: [RecognizedLine] = []
        var currentText = ""
        var currentRect: CGRect?

        func flush() {
            guard let rect = currentRect else { return }
            let text = currentText.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            if !text.isEmpty {
                lines.append(
                    RecognizedLine(
                        text: text,
                        box: normalize(rect, in: bounds),
                        // Not a recognizer's opinion: these characters were
                        // not recognized, they were read.
                        confidence: 1
                    )
                )
            }
            currentText = ""
            currentRect = nil
        }

        for index in 0..<count {
            let character = characters[index]
            if character.isNewline {
                flush()
                continue
            }
            let rect = page.characterBounds(at: index)
            guard rect.width.isFinite, rect.height.isFinite,
                  rect.height > 0 else {
                currentText.append(character)
                continue
            }
            if let running = currentRect, startsNewLine(rect, after: running) {
                flush()
            }
            currentText.append(character)
            currentRect = currentRect.map { $0.union(rect) } ?? rect
        }
        flush()

        guard !lines.isEmpty else { return nil }
        return PageReading(
            reader: .pdfTextLayer,
            pageIndex: pageIndex,
            blocks: BlockAssembly.blocks(
                from: lines,
                pageIndex: pageIndex,
                language: layoutOnly
            ),
            seconds: 0
        )
    }

    /// A new line when the baseline moves by more than half a line, or when
    /// the text jumps back to the left after having advanced — which is what
    /// a wrap looks like in a stream that has no line breaks in it.
    static func startsNewLine(_ rect: CGRect, after running: CGRect) -> Bool {
        let verticalShift = abs(rect.midY - running.midY)
        if verticalShift > running.height * 0.6 { return true }
        return rect.minX < running.minX - running.height
    }

    /// PDF page space has its origin at the bottom left of the crop box.
    static func normalize(_ rect: CGRect, in bounds: CGRect) -> BlockBox {
        BlockBox(
            x: Double((rect.minX - bounds.minX) / bounds.width),
            y: Double(1 - (rect.maxY - bounds.minY) / bounds.height),
            width: Double(rect.width / bounds.width),
            height: Double(rect.height / bounds.height)
        )
    }

    /// The assembler takes a language only to decide how to join wrapped
    /// lines, and the text layer is assembled before anyone has established
    /// which language the page is in. This stands in: it joins the way a
    /// script without spaces does, and the pack's own rules are applied to
    /// the result later.
    static let layoutOnly = SourceLanguage(
        identifier: "und",
        englishName: "Unknown",
        endonym: "Unknown",
        visionRecognitionLanguages: [],
        scriptCharacters: CharacterSet(),
        isSpaceSeparated: false,
        sentenceTerminators: [],
        expansionRatio: 0.1...10,
        promptName: "unknown"
    )
}
