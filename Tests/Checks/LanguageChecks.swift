import DocCore
import Foundation
import LanguageChinese

/// The language pack, and the seam that keeps it out of the pipeline.
func runLanguageChecks(_ report: Report) {
    report.begin("chinese/normalization")
    let chinese = SimplifiedChinese.language

    // The reason this exists: Vision scatters spaces through Chinese and a
    // vision model returns none, so without normalization two identical
    // readings look like a serious disagreement and every block on the page
    // goes to the adjudicator.
    let spaced = "合 同 期 限 为 三 年 。"
    let clean = "合同期限为三年。"
    report.equal(
        chinese.normalizeReading(spaced),
        clean,
        "spaces between Chinese characters are removed"
    )
    report.near(
        TextSimilarity.score(
            chinese.normalizeReading(spaced),
            chinese.normalizeReading(clean)
        ),
        1,
        0.001,
        "the two readings agree once normalized"
    )
    report.expect(
        TextSimilarity.score(spaced, clean) < 0.75,
        "and would not have agreed before"
    )

    // A space that is a real word boundary survives.
    report.equal(
        chinese.normalizeReading("联系 Contact Person 王 小 明"),
        "联系 Contact Person 王小明",
        "spaces beside Latin words are kept"
    )

    report.begin("chinese/script")
    report.near(
        chinese.scriptShare(of: "合同期限为三年"),
        1,
        0.001,
        "Chinese text is all Chinese"
    )
    report.near(
        chinese.scriptShare(of: "The contract runs for three years."),
        0,
        0.001,
        "English text is no Chinese"
    )
    report.expect(
        chinese.scriptShare(of: "Signed by 王小明 on Tuesday") > 0,
        "a kept name registers as Chinese"
    )
    // Kana is a Japanese page, and the pack must not claim it.
    report.expect(
        chinese.scriptShare(of: "ひらがな") < 0.2,
        "kana is not Simplified Chinese"
    )

    report.begin("language/seam")
    // The check that keeps the pack a pack: every rule the pipeline uses is
    // data, so a fabricated language that disagrees on each one produces
    // different behaviour without a line of the pipeline changing.
    let spaced2 = SourceLanguage(
        identifier: "xx",
        englishName: "Spaced",
        endonym: "Spaced",
        visionRecognitionLanguages: ["xx"],
        scriptCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz"),
        isSpaceSeparated: true,
        sentenceTerminators: ["."],
        expansionRatio: 0.5...2,
        promptName: "Spaced"
    )
    report.equal(
        BlockAssembly.join(["one", "two"], language: spaced2),
        "one two",
        "a spaced language joins wrapped lines with a space"
    )
    report.equal(
        BlockAssembly.join(["合同", "期限"], language: chinese),
        "合同期限",
        "an unspaced language does not"
    )
}
