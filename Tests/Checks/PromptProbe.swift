#if MLXEngine
import DocCore
import DocMLX
import Foundation
import LanguageChinese

/// Whether the translating model actually translates.
///
/// A prompt is not code and cannot be checked like code. The failure it has is
/// silent and specific: a small model handed an instruction it half
/// understands returns the source text unchanged, which reads as a page the
/// app declined to translate rather than as a bug in a string. `TextIntegrity`
/// catches it after the fact — "the English is the same text as the Simplified
/// Chinese" — but nothing tells you *which wording* caused it.
///
/// So the wording is measured rather than argued about. Each variant is put to
/// the real model against the same lines, and what is reported is the share of
/// the answer that is still in the source script. `swift run --traits
/// MLXEngine Checks --prompt-probe`.
enum PromptProbe {
    static func run() async {
        let languages = SimplifiedChinese.toEnglish
        let chinese = languages.source
        let store = MLXModelStore()
        let model = await store.model
        print("Probing \(model.displayName)…\n")
        guard (try? await store.prepare()) != nil else {
            print("could not load the model")
            return
        }
        let agent = MLXTextAgent(store: store, name: model.displayName)

        // The blocks the full run left untranslated, plus two it managed, so
        // a variant that fixes one and breaks the other is visible.
        let blocks = [
            "一、支付货款人民币580000元及利息23400元；",
            "二、支付违约金人民币46000元；",
            "三、承担案件受理费9800元、执行费4900元。",
            "限你于收到本通知之日起3日内履行下列义务：",
            "如对本通知有异议，可在收到之日起10日内向本院提出书面异议。"
        ]
        let context = TranslationContext(
            previousSource: "本院于2024年3月15日立案执行，依法向你发出本通知。",
            previousTarget: "This court opened enforcement proceedings on "
                + "15 March 2024 and issues this notice to you accordingly."
        )

        // Each variant builds the whole prompt itself, so what is being
        // compared is the finished string rather than a flag. They differ
        // only in the two sentences around the block: how the context is
        // closed off, and how the block is asked for.
        let source = context.previousSource ?? ""
        let target = context.previousTarget ?? ""

        // What is being compared is how much of the line before is shown, not
        // how the asking is worded — the wording made no measurable
        // difference and this did.
        let variants: [(String, (String) -> String)] = [
            ("no context", { text in
                "Translate this text:\n" + text
            }),
            ("English of the line before", { text in
                "The line before it was translated as:\n" + target + "\n"
                    + "\nTranslate only what follows.\n\n"
                    + "Translate this text:\n" + text
            }),
            ("both halves of the line before", { text in
                "The line before it reads:\n" + source + "\n"
                    + "The line before it was translated as:\n" + target + "\n"
                    + "\nTranslate only what follows.\n\n"
                    + "Translate this text:\n" + text
            }),
            ("both halves, current wording", { text in
                "The line before it reads:\n" + source + "\n"
                    + "The line before it was translated as:\n" + target + "\n"
                    + "\nThat is context. Do not translate any of it.\n\n"
                    + "Translate this text, and nothing else:\n" + text
            })
        ]

        let instructions = AgentPrompts.translationInstructions(
            languages: languages
        )

        // Repeated, because prose is not decoded greedily — a completely
        // greedy decode is where a small model's repetition loops come from —
        // so one block coming back untranslated once is noise and a wording
        // that does it three times in fifteen is not.
        let rounds = 5
        for (label, build) in variants {
            var left = 0
            var examples: [String] = []
            for _ in 0..<rounds {
                for text in blocks {
                    let answer = (try? await agent.answer(
                        instructions: instructions,
                        prompt: build(text),
                        expecting: .prose(approximately: text.count * 4 + 200)
                    )) ?? ""
                    let english = AgentPrompts.stripPreamble(answer)
                    let share = chinese.scriptShare(of: english)
                    guard share > 0.05 else { continue }
                    left += 1
                    examples.append(
                        String(format: "    %.0f%% source  ", share * 100)
                            + english.replacingOccurrences(of: "\n", with: " ")
                    )
                }
            }
            print(
                "\(label): \(left) of \(blocks.count * rounds) came back "
                    + "untranslated"
            )
            for line in examples.prefix(4) { print(line) }
        }
    }
}
#endif
