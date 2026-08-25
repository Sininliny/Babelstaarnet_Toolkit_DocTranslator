import CoreGraphics
import DocCore
import DocIngest
import DocOCR
import Foundation
import LanguageChinese
import PDFKit

/// The engines that need no setup: Apple Vision, and PDFKit's own text.
///
/// These are the checks that actually touch macOS. They are here because the
/// rest of the suite proves the app does the right thing with a reading, and
/// this one proves there is a reading to do it with.
func runEngineChecks(_ report: Report) async {
    report.begin("vision")
    let chinese = SimplifiedChinese.language
    let lines = [
        "本协议自二零二四年三月十五日起生效。",
        "合同期限为三年，罚款为5000元。"
    ]

    guard let image = Fixtures.page(lines: lines) else {
        report.expect(false, "the Chinese fixture page could not be drawn")
        return
    }

    let page = PageImage(
        index: 0,
        image: image,
        pointSize: CGSize(width: image.width, height: image.height)
    )
    let reading = try? await VisionTranscriber().transcribe(
        page,
        language: chinese
    )

    guard let reading else {
        report.expect(false, "Vision returned nothing for a clean page")
        return
    }
    report.expect(
        !reading.isEmpty,
        "Vision reads a rendered Chinese page"
    )

    let recognized = reading.text
    // Not an exact-match assertion: OCR of rendered type is very good but
    // not a promise, and a check that demands perfection fails on a font
    // change rather than on a regression. What must hold is that most of
    // what was printed came back.
    let printed = lines.joined()
    let score = TextSimilarity.score(
        chinese.normalizeReading(recognized),
        printed
    )
    report.expect(
        score > 0.85,
        "Vision recovers the printed text (similarity \(score))"
    )
    report.expect(
        recognized.contains("5000"),
        "figures survive recognition: got “\(recognized)”"
    )
    report.expect(
        reading.blocks.allSatisfy { $0.box.maxY <= 1.001 && $0.box.minY >= -0.001 },
        "boxes are normalized to the page with the origin at the top"
    )
    // The first line is printed above the second, so it must come first.
    if reading.blocks.count >= 2 {
        report.expect(
            reading.blocks[0].box.minY < reading.blocks[1].box.minY,
            "blocks come back in reading order"
        )
    }

    report.begin("ingest")
    guard let pdfData = Fixtures.pdf(lines: lines) else {
        report.expect(false, "the PDF fixture could not be written")
        return
    }
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("laesesalen-check-\(UUID().uuidString).pdf")
    try? pdfData.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    guard let provider = try? DocumentLoader.open(url) else {
        report.expect(false, "a PDF fixture could not be opened")
        return
    }
    report.equal(provider.source.pageCount, 1, "the PDF has one page")
    report.equal(provider.source.kind, .pdf, "and is recognized as a PDF")

    let rendered = try? provider.page(at: 0)
    report.expect(rendered != nil, "the page renders")
    report.expect(
        (rendered?.image.width ?? 0) > 1_500,
        "and renders at a resolution dense Chinese type needs "
            + "(\(rendered?.image.width ?? 0) px)"
    )

    // The text layer: not a recognition, and free.
    let layer = provider.textLayer(at: 0, language: chinese)
    report.expect(layer != nil, "a born-digital PDF carries its own text")
    if let layer {
        report.equal(layer.reader, .pdfTextLayer, "and is marked as such")
        report.expect(
            layer.reader.isAuthoritative,
            "the text layer outranks a recognition"
        )
        let layerScore = TextSimilarity.score(
            chinese.normalizeReading(layer.text),
            printed
        )
        report.expect(
            layerScore > 0.9,
            "the text layer matches what was typeset (\(layerScore))"
        )
    }

    // An image has no text layer to mine, and must say so rather than
    // pretending to an empty one.
    let imageURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("laesesalen-check-\(UUID().uuidString).png")
    if let destination = CGImageDestinationCreateWithURL(
        imageURL as CFURL,
        "public.png" as CFString,
        1,
        nil
    ) {
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        defer { try? FileManager.default.removeItem(at: imageURL) }
        let imageProvider = try? DocumentLoader.open(imageURL)
        report.equal(
            imageProvider?.source.kind,
            .image,
            "a PNG opens as an image"
        )
        report.expect(
            imageProvider?.textLayer(at: 0, language: chinese) == nil,
            "an image has no text layer"
        )
    }
}
