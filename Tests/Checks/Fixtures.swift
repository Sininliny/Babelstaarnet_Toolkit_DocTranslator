import CoreGraphics
import CoreText
import Foundation

/// Pages made of known text, so a recognizer's answer can be compared with
/// what was printed.
enum Fixtures {
    static let font = "PingFangSC-Regular"

    /// A page like the ones this app is actually pointed at: many lines of
    /// small type, with figures in them.
    static let dense = [
        "北京市朝阳区人民法院执行通知书",
        "案号：（2024）京0105执12345号",
        "被执行人：王小明，身份证号110105199003074567",
        "申请执行人：北京安泰科技有限公司",
        "本院于2024年3月15日立案执行，依法向你发出本通知。",
        "限你于收到本通知之日起3日内履行下列义务：",
        "一、支付货款人民币580000元及利息23400元；",
        "二、支付违约金人民币46000元；",
        "三、承担案件受理费9800元、执行费4900元。",
        "逾期未履行的，本院将依法强制执行，并加倍支付迟延履行期间的债务利息。",
        "如对本通知有异议，可在收到之日起10日内向本院提出书面异议。",
        "二〇二四年三月二十日"
    ]


    /// A page of Chinese, drawn at a size a document scan would be.
    ///
    /// An empty string in `lines` is a blank line, which is what separates one
    /// paragraph from the next — the same signal the block assembler reads on
    /// a real page. A `footer` is drawn near the bottom margin, where running
    /// heads and page numbers live.
    static func page(
        lines: [String],
        footer: String? = nil,
        size: CGSize = CGSize(width: 1_240, height: 1_754),
        fontSize: CGFloat = 44,
        startY: CGFloat = 200
    ) -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }

        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(origin: .zero, size: size))
        draw(lines, in: context, size: size, fontSize: fontSize, startY: startY)
        if let footer {
            draw(
                [footer],
                in: context,
                size: size,
                fontSize: fontSize * 0.7,
                startY: size.height - fontSize * 2
            )
        }
        return context.makeImage()
    }

    /// The same page as a PDF with real text in it, which is what a
    /// born-digital document is.
    static func pdf(lines: [String]) -> Data? {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data) else { return nil }
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let context = CGContext(
            consumer: consumer,
            mediaBox: &box,
            nil
        ) else { return nil }

        context.beginPDFPage(nil)
        draw(
            lines,
            in: context,
            size: box.size,
            fontSize: 18,
            startY: 120
        )
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    private static func draw(
        _ lines: [String],
        in context: CGContext,
        size: CGSize,
        fontSize: CGFloat,
        startY: CGFloat
    ) {
        let font = CTFontCreateWithName(font as CFString, fontSize, nil)
        context.setFillColor(gray: 0, alpha: 1)
        context.textMatrix = .identity

        for (index, text) in lines.enumerated() {
            guard !text.isEmpty else { continue }
            let attributed = NSAttributedString(
                string: text,
                attributes: [
                    .font: font,
                    .foregroundColor: CGColor(gray: 0, alpha: 1)
                ]
            )
            let line = CTLineCreateWithAttributedString(attributed)
            context.textPosition = CGPoint(
                x: 90,
                y: size.height - startY - CGFloat(index) * fontSize * 1.8
            )
            CTLineDraw(line, context)
        }
    }
}

/// A form rather than a page of prose.
///
/// The letter in `Sample` is the easy case for the layout-preserving export:
/// wide blocks, one after another down a single column, each with room under
/// it. A form is the hard one, and it is what most documents anyone actually
/// needs translated look like — two columns of cells, a label an inch wide
/// with a figure printed hard against it, rules between them, and twenty rows
/// where the run of type has to stay one size or the page falls apart.
///
/// Fabricated: a water analysis with invented figures, chosen because the
/// shape is what matters here — short labels beside long ones, single
/// characters beside phrases, and a right-hand column that runs out of rows
/// long before the left one does, which is what leaves a block free to
/// sprawl into empty paper.
extension Fixtures {
    struct Row {
        let number: String
        let label: String
        let result: String
        let reference: String
        let unit: String

        init(
            _ number: String,
            _ label: String,
            _ result: String,
            _ reference: String,
            _ unit: String
        ) {
            self.number = number
            self.label = label
            self.result = result
            self.reference = reference
            self.unit = unit
        }
    }

    static let tableHeader = Row("No", "项目", "结果", "参考值", "单位")

    static let tableLeft = [
        Row("1", "总硬度", "68.4", "0-450", "mg/L"),
        Row("2", "溶解性总固体", "312.5", "0-1000", "mg/L"),
        Row("3", "耗氧量", "1.42", "0-3.0", "mg/L"),
        Row("4", "浑浊度", "0.31", "0-1.0", "NTU"),
        Row("5", "色度", "4", "0-15", "度"),
        Row("6", "挥发性酚类", "0.001", "0-0.002", "mg/L"),
        Row("7", "阴离子合成洗涤剂", "0.05", "0-0.3", "mg/L"),
        Row("8", "氨氮", "0.08", "0-0.5", "mg/L"),
        Row("9", "硝酸盐氮", "2.31", "0-10.0", "mg/L"),
        Row("10", "亚硝酸盐氮", "0.004", "0-1.0", "mg/L"),
        Row("11", "氯化物", "24.6", "0-250", "mg/L"),
        Row("12", "硫酸盐", "41.2", "0-250", "mg/L"),
        Row("13", "铁", "0.12", "0-0.3", "mg/L"),
        Row("14", "锰", "0.02", "0-0.1", "mg/L"),
        Row("15", "铜", "0.008", "0-1.0", "mg/L"),
        Row("16", "挥发性有机化合物总量", "0.015", "0-0.05", "mg/L"),
        Row("17", "菌落总数", "12", "0-100", "CFU/mL"),
        Row("18", "游离氯", "0.35", "0.3-4.0", "mg/L"),
        Row("19", "碱度", "96.0", "0-200", "mg/L"),
        Row("20", "钠", "18.7", "0-200", "mg/L")
    ]

    static let tableRight = [
        Row("21", "酸碱度", "7.42", "6.5-8.5", ""),
        Row("22", "电导率", "486", "0-2000", "μS/cm"),
        Row("23", "钙", "41.8", "0-200", "mg/L"),
        Row("24", "镁", "12.3", "0-100", "mg/L")
    ]

    static let tableNote = "注释：碱度的参考值：0.-200"

    /// The whole form, drawn at the size a scan of one would be.
    static func table(
        size: CGSize = CGSize(width: 1_400, height: 1_000),
        fontSize: CGFloat = 26
    ) -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }

        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(origin: .zero, size: size))
        context.setFillColor(gray: 0, alpha: 1)
        context.textMatrix = .identity

        let leading = fontSize * 1.55
        let top = size.height - 60
        // Where each cell in a half begins, as an offset from the half's own
        // left edge. A label column wide enough for four Chinese characters
        // and no wider is the whole difficulty of this page.
        let cells: [CGFloat] = [0, 40, 300, 400, 560]
        let halves: [CGFloat] = [60, 740]

        func draw(_ row: Row, half: CGFloat, baseline: CGFloat) {
            let texts = [
                row.number, row.label, row.result, row.reference, row.unit
            ]
            for (index, text) in texts.enumerated() where !text.isEmpty {
                let attributed = NSAttributedString(
                    string: text,
                    attributes: [
                        .font: CTFontCreateWithName(
                            font as CFString,
                            fontSize,
                            nil
                        ),
                        .foregroundColor: CGColor(gray: 0, alpha: 1)
                    ]
                )
                context.textPosition = CGPoint(
                    x: half + cells[index],
                    y: baseline
                )
                CTLineDraw(
                    CTLineCreateWithAttributedString(attributed),
                    context
                )
            }
        }

        for (index, half) in halves.enumerated() {
            draw(tableHeader, half: half, baseline: top)
            let rows = index == 0 ? tableLeft : tableRight
            for (step, row) in rows.enumerated() {
                draw(
                    row,
                    half: half,
                    baseline: top - leading * CGFloat(step + 1)
                )
            }
        }

        // The rules. They are not text, nothing reads them, and they are the
        // first thing to go when a block erases more of the page than it
        // covers.
        context.setStrokeColor(gray: 0, alpha: 1)
        context.setLineWidth(2)
        context.move(to: CGPoint(x: 50, y: top - leading * 0.45))
        context.addLine(to: CGPoint(x: size.width - 40, y: top - leading * 0.45))
        context.move(to: CGPoint(x: 700, y: top + fontSize))
        context.addLine(
            to: CGPoint(x: 700, y: top - leading * CGFloat(tableLeft.count + 1))
        )
        context.strokePath()

        let note = NSAttributedString(
            string: tableNote,
            attributes: [
                .font: CTFontCreateWithName(
                    font as CFString,
                    fontSize * 0.85,
                    nil
                ),
                .foregroundColor: CGColor(gray: 0, alpha: 1)
            ]
        )
        context.textPosition = CGPoint(
            x: 60,
            y: top - leading * CGFloat(tableLeft.count + 2)
        )
        CTLineDraw(CTLineCreateWithAttributedString(note), context)

        return context.makeImage()
    }
}
