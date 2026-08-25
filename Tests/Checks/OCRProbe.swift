import CoreGraphics
import DocCore
import DocOCR
import Foundation
import LanguageChinese

/// What Apple Vision makes of a page, printed rather than asserted.
enum OCRProbe {
    static func run() async {
        boundaryCheck()
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
            for block in reading?.blocks ?? [] {
                print("   [\(block.kind.rawValue)] \(block.text.prefix(70))")
            }
        }
    }
}

extension OCRProbe {
    /// What the sentence boundary makes of a Chinese line, in isolation.
    static func boundaryCheck() {
        let chinese = SimplifiedChinese.language
        let boundary = chinese.sentenceBoundary
        let samples = [
            "本院于2024年3月15日立案执行，依法向你发出本通知。限你于收到本通知之日起3日内履行下列义务：",
            "一、支付货款人民币580000元及利息23400元；二、支付违约金人民币46000元；",
            Fixtures.dense.joined()
        ]
        for sample in samples {
            let stops = boundary.stopLocations(in: sample)
            let ranges = boundary.sentenceRanges(in: sample)
            print("stops \(stops.count), sentences \(ranges.count) — \(sample.prefix(40))")
        }
    }
}
