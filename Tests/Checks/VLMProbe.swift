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
    static func run() async {
        let chinese = SimplifiedChinese.language
        let lines = Fixtures.dense
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
