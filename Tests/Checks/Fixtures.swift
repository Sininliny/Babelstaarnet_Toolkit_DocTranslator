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
