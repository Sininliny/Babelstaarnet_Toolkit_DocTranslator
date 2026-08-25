import CoreGraphics
import DocCore
import DocOCR
import Foundation
import LanguageChinese

/// What Apple Vision makes of a page, printed rather than asserted.
enum OCRProbe {
    static func run() async {
        let chinese = SimplifiedChinese.language
        let sizes: [CGFloat] = [30, 40, 52]
        for fontSize in sizes {
            guard let page = Fixtures.page(
                lines: Fixtures.dense,
                footer: "第 1 页",
                fontSize: fontSize,
                startY: 150
            ) else { continue }
            let reading = try? await VisionTranscriber().transcribe(
                PageImage(
                    index: 0,
                    image: page,
                    pointSize: CGSize(
                        width: page.width,
                        height: page.height
                    )
                ),
                language: chinese
            )
            let text = reading?.text ?? ""
            let score = TextSimilarity.score(
                chinese.normalizeReading(
                    text.replacingOccurrences(of: "\n", with: "")
                ),
                Fixtures.dense.joined()
            )
            print(
                "--- \(Int(fontSize)) px: \(reading?.blocks.count ?? 0) blocks, "
                    + "similarity " + String(format: "%.2f", score) + " ---"
            )
            print(text.prefix(160).replacingOccurrences(of: "\n", with: " ⏎ "))
        }
    }
}
