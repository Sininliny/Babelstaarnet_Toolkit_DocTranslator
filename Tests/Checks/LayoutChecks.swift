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

/// The sentence, which is the unit everything downstream works in.
func runSentenceChecks(_ report: Report) {
    report.begin("sentences/chinese")
    let chinese = SimplifiedChinese.language
    let boundary = chinese.sentenceBoundary

    // The rule the port could not do without: 。 is followed immediately by
    // the next sentence, and requiring a space after it — which is right for
    // every language the algorithm was written for — finds no stops at all on
    // a Chinese page.
    report.equal(
        boundary.sentenceRanges(in: "合同期限为三年。罚款为5000元。").count,
        2,
        "a full-width stop ends a sentence with nothing after it"
    )
    report.equal(
        boundary.sentenceRanges(in: "一、支付货款；二、支付违约金；").count,
        2,
        "so does a full-width semicolon"
    )
    // And the ASCII period keeps its guard, because in Chinese text it is
    // nearly always a decimal point or part of a name.
    report.equal(
        boundary.sentenceRanges(in: "利率为3.5%，期限三年。").count,
        1,
        "a decimal point is not a sentence stop"
    )
    report.expect(
        boundary.endsSentence("本通知自即日起生效。"),
        "a line ending in 。 ends a sentence"
    )
    report.expect(
        !boundary.endsSentence("被执行人：王小明"),
        "and a line with no stop does not"
    )

    report.begin("sentences/assembly")

    func line(
        _ text: String,
        y: Double,
        height: Double = 0.02
    ) -> RecognizedLine {
        RecognizedLine(
            text: text,
            box: BlockBox(x: 0.1, y: y, width: 0.8, height: height),
            confidence: 0.9
        )
    }

    // A sentence printed across two wrapped lines is one block; two
    // sentences on one line are two.
    let wrapped = BlockAssembly.blocks(
        from: [
            line("本院于2024年3月15日立案执行，", y: 0.10),
            line("依法向你发出本通知。限你于三日内履行。", y: 0.13)
        ],
        pageIndex: 0,
        language: chinese
    )
    report.equal(wrapped.count, 2, "the run splits into its two sentences")
    report.equal(
        wrapped.first?.text,
        "本院于2024年3月15日立案执行，依法向你发出本通知。",
        "the first is assembled across both lines"
    )
    report.equal(
        wrapped.last?.text,
        "限你于三日内履行。",
        "and the second is the rest of the second line"
    )

    // The boxes: a sentence that shares a line takes its share of it, so the
    // layout-preserving export does not have two blocks erasing the same
    // pixels.
    if wrapped.count == 2 {
        let first = wrapped[0].box
        let second = wrapped[1].box
        report.expect(
            second.minX > first.minX,
            "the second sentence starts to the right of the first's margin"
        )
        report.expect(
            second.maxX <= first.maxX + 0.001,
            "and ends no further right than the line does"
        )
        report.expect(
            first.minY < second.minY + 0.001,
            "the first sentence starts no lower than the second"
        )
    }

    report.begin("sentences/type size")

    // The signal this project was missing, and the parent had: a heading is
    // set larger, and must not be swallowed by the paragraph under it even
    // when the gap and the column say it could be.
    let heading = line("关于门禁系统升级的通知", y: 0.10, height: 0.04)
    let body = line("为加强办公区域安全管理，本院决定升级。", y: 0.15)
    report.expect(
        !BlockAssembly.continuesLine(heading, body),
        "type of a different size is not the same run of text"
    )
    report.expect(
        BlockAssembly.continuesLine(
            line("为加强办公区域安全管理，", y: 0.15),
            line("本院决定升级。", y: 0.18)
        ),
        "type of the same size, one line apart, is"
    )
    report.expect(
        !BlockAssembly.continuesLine(
            RecognizedLine(
                text: "左栏文字",
                box: BlockBox(x: 0.06, y: 0.15, width: 0.36, height: 0.02),
                confidence: 0.9
            ),
            RecognizedLine(
                text: "右栏文字",
                box: BlockBox(x: 0.56, y: 0.18, width: 0.36, height: 0.02),
                confidence: 0.9
            )
        ),
        "and a line in the next column is not"
    )
}
