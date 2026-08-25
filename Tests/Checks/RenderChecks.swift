import CoreGraphics
import DocCore
import DocRender
import Foundation
import LanguageChinese
import PDFKit

/// Putting the English back on the page it came from.
///
/// Checked against a fabricated form rather than a document, for the same
/// reason the layout checks are: the faults worth catching here are
/// geometric, and stating them as boxes states them exactly. A form is the
/// shape that finds them — twenty rows of one size, a label an inch wide with
/// a figure printed hard against it, a rule between two columns, and a
/// right-hand column that runs out of rows long before the left one does.
func runRenderChecks(_ report: Report) {
    let box = CGRect(x: 0, y: 0, width: 600, height: 800)
    let page = FormPage()

    report.begin("render/type size")

    let sizes = LayoutPreservingPDF.typeSizes(for: page.blocks, in: box)
    let labels = page.leftLabels.compactMap { sizes[$0.id] }
    report.equal(labels.count, page.leftLabels.count, "every label was sized")
    report.expect(
        Set(labels.map { ($0 * 100).rounded() }).count == 1,
        "a run of rows is set at one size, whatever their boxes measured"
    )
    // The boxes deliberately differ by a few percent, the way a recognizer's
    // do. Fitted block by block, that alone puts half a table one step down
    // from the other half.
    report.expect(
        Set(page.leftLabels.map { $0.source.box.height }).count > 1,
        "and the boxes they were measured in did not agree"
    )
    report.expect(
        (sizes[page.heading.id] ?? 0) > (labels.first ?? 0),
        "a heading is still set larger than the rows under it"
    )
    // The fault this is really for: a reader hands back two rows as one
    // block, so its box is three lines tall and its "type size" is three
    // lines high. Set at that, two words print over everything nearby.
    report.expect(
        (sizes[page.merged.id] ?? 0) <= (labels.first ?? 0) * 2,
        "a block whose box is far taller than its run is not set that large"
    )
    // And the other way a cell gets set like a title: the classifier reads a
    // one-word cell measured a little taller than the row above it as a
    // heading, which on a form is most of the unit column. Set as one it
    // comes out bold and larger in the middle of a table.
    report.equal(
        sizes[page.strayHeading.id],
        labels.first,
        "a cell classified as a heading is set as the row it sits in"
    )

    report.begin("render/space")

    let label = page.leftLabels[3]
    let figure = page.leftFigures[3]
    let space = LayoutPreservingPDF.space(
        for: label,
        among: page.blocks,
        in: box
    )
    let measured = LayoutPreservingPDF.rect(for: label.source.box, in: box)
    report.expect(
        space.width > measured.width,
        "a label uses the empty paper beside it"
    )
    report.expect(
        space.maxX
            <= LayoutPreservingPDF.rect(for: figure.source.box, in: box).minX,
        "and stops before the figure it labels"
    )
    report.expect(
        space.minX == measured.minX,
        "a cell in a row is not centred, wherever on the paper it sits"
    )

    // The last cell in a row has nothing beside it on its own lines, and the
    // empty half of a form is not empty paper.
    let unit = page.leftUnits[8]
    let across = LayoutPreservingPDF.space(
        for: unit,
        among: page.blocks,
        in: box
    )
    report.expect(
        across.maxX <= LayoutPreservingPDF.rect(
            for: page.rightLabels[0].source.box,
            in: box
        ).minX,
        "and the last cell in a row does not cross into the other column"
    )

    // A title alone on its lines keeps its middle.
    let titled = LayoutPreservingPDF.space(
        for: page.title,
        among: page.blocks,
        in: box
    )
    let titleBox = LayoutPreservingPDF.rect(for: page.title.source.box, in: box)
    report.expect(
        titled.minX < titleBox.minX && titled.maxX > titleBox.maxX,
        "a centred title widens both ways, so it is still centred"
    )

    report.begin("render/room below")

    // Rows in a dense table are measured overlapping as often as not.
    let floor = LayoutPreservingPDF.roomBelow(
        page.overlapping,
        among: page.blocks,
        within: LayoutPreservingPDF.space(
            for: page.overlapping,
            among: page.blocks,
            in: box
        ),
        in: box
    )
    report.expect(
        floor > box.minY,
        "a row that overlaps the one under it still finds a floor"
    )
    report.near(
        Double(floor),
        Double(LayoutPreservingPDF.rect(
            for: page.leftLabels[6].source.box,
            in: box
        ).maxY),
        1,
        "and the floor is the top of that row"
    )

    report.begin("render/page")

    guard let pdf = try? LayoutPreservingPDF.render(
        page.document,
        pages: page
    ) else {
        report.expect(false, "the form was exported")
        return
    }

    // Nothing may be dropped. CoreText draws no line at all rather than a
    // clipped one, so a block fitted a hair too large does not overflow —
    // it disappears, and a translation with a row missing looks finished.
    // Compared with the spaces taken out, because a block that had to wrap
    // comes back out of the PDF with a line break where its space was, and
    // that is the layout doing its job rather than a word going missing.
    let written = unspaced(PDFDocument(data: pdf)?.string ?? "")
    for block in page.blocks where block.text != block.source.text {
        report.expect(
            written.contains(unspaced(block.text)),
            "\(block.text) reached the page"
        )
    }

    // The rule between the two columns is not text, nothing read it, and no
    // block's English comes near it. It is on the page unless a patch erased
    // paper its block never wrote on.
    report.expect(
        page.ruleSurvives(in: pdf),
        "the rule between the columns is still there afterwards"
    )
}

private func unspaced(_ text: String) -> String {
    text.components(separatedBy: .whitespacesAndNewlines).joined()
}

/// A form: twenty rows in the left half, four in the right, a rule between
/// them, and a couple of blocks measured the way a recognizer really measures
/// them rather than the way a fixture would like.
private struct FormPage: PageProvider {
    let source = DocumentSource(
        url: URL(fileURLWithPath: "/tmp/form.png"),
        kind: .image,
        pageCount: 1
    )
    /// Where the rule is drawn, as a share of the page's width.
    static let rule = 0.53

    let title: TranslatedBlock
    let heading: TranslatedBlock
    let leftLabels: [TranslatedBlock]
    let leftFigures: [TranslatedBlock]
    let leftUnits: [TranslatedBlock]
    let rightLabels: [TranslatedBlock]
    /// A row measured overlapping the one under it.
    var overlapping: TranslatedBlock { leftLabels[5] }
    /// Two rows the reader handed back as one block.
    let merged: TranslatedBlock
    /// A unit cell the classifier read as a heading, which is what it does
    /// with a short cell measured slightly taller than its neighbours.
    var strayHeading: TranslatedBlock { leftUnits[2] }

    init() {
        title = placed(
            "水质检测报告",
            "Water analysis report",
            x: 0.28, y: 0.02, width: 0.22, height: 0.03,
            kind: .heading,
            order: 0
        )
        heading = placed(
            "项目",
            "Item",
            x: 0.08, y: 0.07, width: 0.10, height: 0.032,
            kind: .heading,
            order: 1
        )

        var labels: [TranslatedBlock] = []
        var figures: [TranslatedBlock] = []
        var units: [TranslatedBlock] = []
        for row in 0..<16 {
            let y = 0.12 + Double(row) * 0.045
            // Boxes that disagree by a few percent about the same type, and
            // one row measured far enough down to overlap the next.
            let height = [0.024, 0.027, 0.025][row % 3]
            let top = row == 5 ? y + 0.021 : y
            labels.append(placed(
                "项目\(row)",
                "Item \(row)",
                x: 0.08, y: top, width: 0.13, height: height,
                order: 10 + row
            ))
            figures.append(placed(
                "\(row).0",
                "\(row).0",
                x: 0.32, y: y, width: 0.08, height: height,
                order: 40 + row
            ))
            units.append(placed(
                "度",
                "deg",
                x: 0.44, y: y, width: 0.06, height: height,
                kind: row == 2 ? .heading : .tableRow,
                order: 70 + row
            ))
        }
        leftLabels = labels
        leftFigures = figures
        leftUnits = units

        rightLabels = (0..<4).map { row in
            placed(
                "右项\(row)",
                "Right item \(row)",
                x: 0.57, y: 0.12 + Double(row) * 0.045, width: 0.13,
                height: 0.026,
                order: 100 + row
            )
        }
        merged = placed(
            "钙镁",
            "Calcium Magnesium",
            x: 0.57, y: 0.30, width: 0.13, height: 0.11,
            order: 120
        )
    }

    var blocks: [TranslatedBlock] {
        [title, heading] + leftLabels + leftFigures + leftUnits
            + rightLabels + [merged]
    }

    var document: TranslatedDocument {
        TranslatedDocument(
            source: source,
            languages: SimplifiedChinese.toEnglish,
            pages: [TranslatedPage(index: 0, blocks: blocks)],
            engines: EngineRecord(
                readers: ["Vision OCR"],
                adjudicator: nil,
                translator: "scripted",
                reviewer: nil
            )
        )
    }

    func page(at index: Int) throws -> PageImage {
        PageImage(index: index, image: drawn, pointSize: CGSize(width: 600, height: 800))
    }

    func textLayer(at index: Int, language: SourceLanguage) -> PageReading? {
        nil
    }

    /// White paper with one black rule down the middle.
    private var drawn: CGImage {
        let context = CGContext(
            data: nil,
            width: 600,
            height: 800,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 600, height: 800))
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(
            CGRect(x: 600 * Self.rule - 1, y: 80, width: 2, height: 640)
        )
        return context.makeImage()!
    }

    /// How much of that rule is left after the export.
    func ruleSurvives(in pdf: Data) -> Bool {
        guard let document = PDFDocument(data: pdf),
              let page = document.page(at: 0),
              let context = CGContext(
                data: nil,
                width: 600,
                height: 800,
                bitsPerComponent: 8,
                bytesPerRow: 600 * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return false }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 600, height: 800))
        page.draw(with: .mediaBox, to: context)
        guard let pixels = context.data else { return false }

        let column = Int(600 * Self.rule)
        var dark = 0
        for row in 80..<720 {
            let offset = (row * 600 + column) * 4
            let value = pixels.load(fromByteOffset: offset, as: UInt8.self)
            if value < 128 { dark += 1 }
        }
        return dark > Int(Double(720 - 80) * 0.9)
    }
}

private func placed(
    _ chinese: String,
    _ english: String,
    x: Double,
    y: Double,
    width: Double,
    height: Double,
    lines: Int = 1,
    kind: BlockKind = .tableRow,
    order: Int
) -> TranslatedBlock {
    TranslatedBlock(
        source: ReconciledBlock(
            pageIndex: 0,
            order: order,
            box: BlockBox(x: x, y: y, width: width, height: height),
            kind: kind,
            lineCount: lines,
            text: chinese,
            candidates: [.visionOCR: chinese],
            agreement: 1,
            settlement: .unanimous
        ),
        firstDraft: english,
        confidence: Confidence(score: 0.9)
    )
}
