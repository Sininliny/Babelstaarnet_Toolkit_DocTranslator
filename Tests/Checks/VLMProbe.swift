#if MLXEngine
import CoreGraphics
import CoreImage
import DocCore
import DocMLX
import Foundation
import LanguageChinese
import MLXLMCommon

/// Finds out why a vision model answered without looking.
enum VLMProbe {
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

    static func run() async {
        let chinese = SimplifiedChinese.language
        let lines = dense
        guard let page = Fixtures.page(
            lines: lines,
            fontSize: 30,
            startY: 150
        ) else { return }
        let printed = lines.joined()
        let store = MLXModelStore()
        guard let container = try? await store.prepare() else {
            print("could not load the model")
            return
        }

        let image = ImageScaling.scaled(page, longSide: 1_400) ?? page
        let attempts: [(String, UserInput.Processing)] = [
            ("512", .init(resize: CGSize(width: 512, height: 512))),
            ("768", .init(resize: CGSize(width: 768, height: 768))),
            ("1024", .init(resize: CGSize(width: 1_024, height: 1_024))),
            ("1280", .init(resize: CGSize(width: 1_280, height: 1_280)))
        ]

        for (label, processing) in attempts {
            let session = ChatSession(
                container,
                instructions: AgentPrompts.transcriptionInstructions(
                    for: chinese
                ),
                generateParameters: GenerateParameters(
                    maxTokens: 1_200,
                    temperature: 0
                ),
                processing: processing
            )
            let started = Date()
            do {
                let answer = try await session.respond(
                    to: AgentPrompts.transcriptionRequest(for: chinese),
                    image: .ciImage(CIImage(cgImage: image))
                )
                let seconds = Date().timeIntervalSince(started)
                let cleaned = chinese.normalizeReading(
                    AgentPrompts.stripFences(answer)
                        .replacingOccurrences(of: "\n", with: "")
                )
                let score = TextSimilarity.score(cleaned, printed)
                // Every figure on the page, and whether it survived.
                let wanted = TextIntegrity.numberRuns(in: printed)
                let got = Set(TextIntegrity.numberRuns(in: cleaned))
                let kept = wanted.filter { got.contains($0) }.count
                print(
                    "--- \(label): similarity "
                        + String(format: "%.3f", score)
                        + ", figures \(kept)/\(wanted.count), "
                        + String(format: "%.1f", seconds) + "s ---"
                )
                print(cleaned.prefix(120))
            } catch {
                print("--- \(label) — threw: \(error) ---")
            }
        }

        print("printed: \(printed.prefix(120))")
    }
}
#endif
