import CoreGraphics
import DocAgents
import DocCore
import DocIngest
import DocOCR
import DocRender
import Foundation
import ImageIO
import LanguageChinese
import PDFKit
import UniformTypeIdentifiers

/// The two output modes that produce a file rather than a report.
func runOutputModeChecks(_ report: Report) async {
    report.begin("output/plain text")
    let chinese = SimplifiedChinese.language

    let plainDocument = documentForExport()
    let text = PlainTextExport.render(plainDocument)

    report.expect(
        text.contains("The contract runs for three years."),
        "the plain text carries the translation"
    )
    // The point of this mode is that there is nothing to strip out.
    for markup in ["#", ">", "<", "⚠︎", "**", "Læsesalen", "Vision"] {
        report.expect(
            !text.contains(markup),
            "plain text must not contain \(markup)"
        )
    }
    report.expect(
        !text.contains("第 1 页"),
        "a page number is not part of the text"
    )
    report.expect(
        !text.contains("合同期限"),
        "plain text is the translation, not the source"
    )
    report.expect(
        text.contains("• The first item."),
        "list items keep their bullet"
    )
    report.expect(
        text.hasSuffix("\n") && !text.hasSuffix("\n\n\n"),
        "the file ends with exactly one newline"
    )

    report.begin("output/same document")

    // End to end: a real page, read by Vision, translated by a fake, drawn
    // back onto its own pixels, and then read again to see what is on it.
    let lines = [
        "本协议自二零二四年三月十五日起生效。",
        "合同期限为三年，罚款为5000元。"
    ]
    guard let image = Fixtures.page(lines: lines) else {
        report.expect(false, "the fixture page could not be drawn")
        return
    }
    let pngURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("laesesalen-mode-\(UUID().uuidString).png")
    guard let destination = CGImageDestinationCreateWithURL(
        pngURL as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
    ) else {
        report.expect(false, "the fixture page could not be written")
        return
    }
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
    defer { try? FileManager.default.removeItem(at: pngURL) }

    guard let provider = try? DocumentLoader.open(pngURL) else {
        report.expect(false, "the fixture page could not be opened")
        return
    }

    let englishFor = "This agreement takes effect on 15 March 2024."
    let translator = ScriptedTranslator { _ in englishFor }
    let document = try? await TranslationPipeline(
        languages: SimplifiedChinese.toEnglish,
        engines: Engines(
            readers: [VisionTranscriber()],
            textAgent: nil,
            machineTranslator: translator,
            preference: .fastest
        )
    ).run(provider)

    guard let document, !document.blocks.isEmpty else {
        report.expect(false, "the fixture page produced no blocks")
        return
    }

    guard let pdf = try? LayoutPreservingPDF.render(
        document,
        pages: provider
    ) else {
        report.expect(false, "the translated PDF could not be rendered")
        return
    }

    guard let written = PDFDocument(data: pdf), written.pageCount == 1 else {
        report.expect(false, "the translated PDF is not a readable PDF")
        return
    }
    report.equal(
        written.pageCount,
        document.pages.count,
        "the translated PDF has the same number of pages"
    )

    // The English is real text in the PDF, not a picture of text.
    let extracted = written.page(at: 0)?.string ?? ""
    report.expect(
        extracted.contains("March"),
        "the English is selectable text in the PDF: got “\(extracted.prefix(80))”"
    )

    // And the page itself: read it back with the same recognizer that read
    // the original. If the Chinese were still showing through, this is where
    // it would appear.
    guard let renderedPage = written.page(at: 0) else { return }
    let bounds = renderedPage.bounds(for: .cropBox)
    let scale = 2.0
    guard let context = CGContext(
        data: nil,
        width: Int(bounds.width * scale),
        height: Int(bounds.height * scale),
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ) else { return }
    context.setFillColor(gray: 1, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: bounds.width * scale, height: bounds.height * scale))
    context.scaleBy(x: scale, y: scale)
    renderedPage.draw(with: .cropBox, to: context)

    guard let readBack = context.makeImage() else { return }
    let reading = try? await VisionTranscriber().transcribe(
        PageImage(
            index: 0,
            image: readBack,
            pointSize: bounds.size
        ),
        language: chinese
    )
    let onThePage = reading?.text ?? ""
    report.expect(
        chinese.scriptShare(of: onThePage) < 0.1,
        "no Chinese is left on the translated page: got “\(onThePage.prefix(60))”"
    )
    report.expect(
        onThePage.lowercased().contains("agreement")
            || onThePage.lowercased().contains("march"),
        "the English is legible on the translated page: got "
            + "“\(onThePage.prefix(60))”"
    )

    report.begin("output/geometry")
    // A block with no geometry has no place on the page, and must not be
    // painted somewhere plausible.
    let page = CGRect(x: 0, y: 0, width: 100, height: 200)
    let top = LayoutPreservingPDF.rect(
        for: BlockBox(x: 0.1, y: 0, width: 0.5, height: 0.1),
        in: page
    )
    report.near(
        top.maxY,
        200,
        0.001,
        "a block at the top of the page is at the top of the PDF page"
    )
    report.near(top.minX, 10, 0.001, "and at the same distance from the left")
}

/// A small finished document, built by hand so the export checks do not
/// depend on a model or a recognizer.
private func documentForExport() -> TranslatedDocument {
    func made(
        _ source: String,
        _ english: String,
        kind: BlockKind = .paragraph
    ) -> TranslatedBlock {
        TranslatedBlock(
            source: ReconciledBlock(
                pageIndex: 0,
                order: 0,
                box: BlockBox(x: 0.1, y: 0.1, width: 0.8, height: 0.05),
                kind: kind,
                text: source,
                candidates: [.visionOCR: source],
                agreement: 1,
                settlement: .unanimous
            ),
            firstDraft: english,
            confidence: Confidence(score: 1)
        )
    }

    return TranslatedDocument(
        source: DocumentSource(
            url: URL(fileURLWithPath: "/tmp/合同.pdf"),
            kind: .pdf,
            pageCount: 1
        ),
        languages: SimplifiedChinese.toEnglish,
        pages: [
            TranslatedPage(
                index: 0,
                blocks: [
                    made("合同期限为三年。", "The contract runs for three years."),
                    made("第一项。", "The first item.", kind: .listItem),
                    made("第 1 页", "第 1 页", kind: .pageFurniture)
                ]
            )
        ],
        engines: EngineRecord(
            readers: ["Vision OCR"],
            adjudicator: nil,
            translator: "Apple Translation",
            reviewer: nil
        )
    )
}

/// The colours the layout-preserving export paints with.
///
/// Worth checking on its own, because getting it wrong does not fail — it
/// produces a translated page that looks like a faded photocopy, which is
/// easy to mistake for a rendering quirk and hard to trace back to a
/// histogram.
func runColourChecks(_ report: Report) {
    report.begin("colours")

    guard let page = Fixtures.page(
        lines: ["合同期限为三年，罚款为5000元。"],
        size: CGSize(width: 800, height: 200),
        fontSize: 40,
        startY: 90
    ) else {
        report.expect(false, "the colour fixture could not be drawn")
        return
    }

    // A box around the line that was drawn.
    let colours = PageColours.sample(
        page,
        box: CGRect(x: 80, y: 60, width: 640, height: 60)
    )
    let ink = PageColours.luminance(colours.ink)
    let background = PageColours.luminance(colours.background)

    report.expect(
        background > 0.9,
        "white paper samples as white (got \(background))"
    )
    report.expect(
        ink < 0.4,
        "black type samples as black, not as the mid-grey that antialiasing "
            + "makes most of (got \(ink))"
    )
    report.expect(
        background - ink > 0.5,
        "and the two are far enough apart to read"
    )
}
