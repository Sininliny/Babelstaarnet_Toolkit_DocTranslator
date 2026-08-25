import DocCore
import Foundation
import LanguageChinese

/// Turning lines into paragraphs, and paragraphs into reading order.
///
/// Checked against fabricated layouts rather than against images, because the
/// failures worth catching here are geometric and an image would only make
/// them harder to state: a two-column page read straight across, a paragraph
/// split at every line, a heading swallowed by the text under it.
func runLayoutChecks(_ report: Report) {
    report.begin("layout")
    let chinese = SimplifiedChinese.language

    func line(
        _ text: String,
        x: Double,
        y: Double,
        width: Double = 0.35,
        height: Double = 0.02
    ) -> RecognizedLine {
        RecognizedLine(
            text: text,
            box: BlockBox(x: x, y: y, width: width, height: height),
            confidence: 0.9
        )
    }

    // One column: consecutive lines close together are one paragraph.
    let paragraph = [
        line("本协议由甲乙双方于二零二四年", x: 0.1, y: 0.10, width: 0.8),
        line("三月十五日在北京签订。", x: 0.1, y: 0.13, width: 0.8)
    ]
    let joined = BlockAssembly.blocks(
        from: paragraph,
        pageIndex: 0,
        language: chinese
    )
    report.equal(joined.count, 1, "two close lines make one paragraph")
    report.equal(
        joined.first?.text,
        "本协议由甲乙双方于二零二四年三月十五日在北京签订。",
        "wrapped Chinese lines join with no space"
    )

    // A Latin phrase broken across lines gets its space back.
    let latin = BlockAssembly.blocks(
        from: [
            line("联系 Contact", x: 0.1, y: 0.1, width: 0.8),
            line("Person: Wang", x: 0.1, y: 0.13, width: 0.8)
        ],
        pageIndex: 0,
        language: chinese
    )
    report.equal(
        latin.first?.text,
        "联系 Contact Person: Wang",
        "a Latin word break keeps its space"
    )

    // A gap of more than a line ends the paragraph.
    let split = BlockAssembly.blocks(
        from: [
            line("第一段。", x: 0.1, y: 0.10, width: 0.8),
            line("第二段。", x: 0.1, y: 0.30, width: 0.8)
        ],
        pageIndex: 0,
        language: chinese
    )
    report.equal(split.count, 2, "a wide gap ends a paragraph")

    // Two columns. Read straight across, this page comes out interleaved.
    var columns: [RecognizedLine] = []
    for step in 0..<5 {
        let y = 0.2 + Double(step) * 0.05
        columns.append(line("左\(step)", x: 0.06, y: y, width: 0.36))
        columns.append(line("右\(step)", x: 0.56, y: y, width: 0.36))
    }
    let ordered = BlockAssembly.readingOrder(of: columns)
    let texts = ordered.map(\.text)
    report.equal(
        texts,
        ["左0", "左1", "左2", "左3", "左4", "右0", "右1", "右2", "右3", "右4"],
        "a two-column page is read down each column, not across"
    )
    report.expect(
        BlockAssembly.gutter(in: columns) != nil,
        "the gutter between two columns is found"
    )

    // A single column must not be split by the ragged right edge of prose.
    let prose = (0..<6).map { step in
        line("正文第\(step)行内容", x: 0.1, y: 0.2 + Double(step) * 0.04, width: 0.78)
    }
    report.expect(
        BlockAssembly.gutter(in: prose) == nil,
        "ordinary prose has no gutter"
    )

    // A banner headline across both columns separates what is above from
    // what is below.
    var banner = columns
    banner.append(line("通知", x: 0.06, y: 0.45, width: 0.86))
    for step in 0..<4 {
        let y = 0.5 + Double(step) * 0.05
        banner.append(line("下左\(step)", x: 0.06, y: y, width: 0.36))
        banner.append(line("下右\(step)", x: 0.56, y: y, width: 0.36))
    }
    let bannerOrder = BlockAssembly.readingOrder(of: banner).map(\.text)
    let headlineIndex = bannerOrder.firstIndex(of: "通知") ?? -1
    let firstLower = bannerOrder.firstIndex(of: "下左0") ?? -1
    let lastUpper = bannerOrder.lastIndex(of: "右4") ?? -1
    report.expect(
        lastUpper < headlineIndex && headlineIndex < firstLower,
        "a full-width line separates the columns above it from those below"
    )

    report.begin("layout/kinds")
    // Page furniture: short, alone, pinned to the bottom.
    let furniture = BlockAssembly.blocks(
        from: [
            line("正文内容在这里。", x: 0.1, y: 0.3, width: 0.8),
            line("第 3 页", x: 0.45, y: 0.96, width: 0.1)
        ],
        pageIndex: 0,
        language: chinese
    )
    report.equal(
        furniture.last?.kind,
        .pageFurniture,
        "a page number at the foot is furniture"
    )
    report.expect(
        !BlockKind.pageFurniture.isTranslatable,
        "furniture is never sent to a translator"
    )

    // A short sentence set large is not a heading, however heading-shaped
    // its box is.
    let standfirst = BlockAssembly.classify(
        [line("请勿在此区域吸烟。", x: 0.1, y: 0.1, width: 0.5, height: 0.05)],
        box: BlockBox(x: 0.1, y: 0.1, width: 0.5, height: 0.05),
        medianHeight: 0.02,
        language: chinese
    )
    report.equal(
        standfirst,
        .paragraph,
        "a line ending in 。 is a sentence, not a heading"
    )
    let title = BlockAssembly.classify(
        [line("关于门禁系统升级的通知", x: 0.1, y: 0.1, width: 0.5, height: 0.05)],
        box: BlockBox(x: 0.1, y: 0.1, width: 0.5, height: 0.05),
        medianHeight: 0.02,
        language: chinese
    )
    report.equal(title, .heading, "and a title with no stop still is one")

    for marker in ["1. 第一项", "（二）第二项", "第三条 规定如下", "• 要点"] {
        report.expect(
            BlockAssembly.isListItem(marker),
            "\(marker) is a list item"
        )
    }
    report.expect(
        !BlockAssembly.isListItem("本合同的内容如下。"),
        "ordinary prose is not a list item"
    )
}
