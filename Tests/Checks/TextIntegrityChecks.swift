import DocCore
import Foundation
import LanguageChinese

/// The checks that need no model — the half of the double-check that a second
/// language model cannot be trusted to do.
func runTextIntegrityChecks(_ report: Report) {
    report.begin("integrity")
    let chinese = SimplifiedChinese.language
    let english = TargetLanguage.english

    func findings(
        _ source: String,
        _ translation: String,
        brief: TranslationBrief = .none
    ) -> [IntegrityFinding] {
        TextIntegrity.check(
            source: source,
            translation: translation,
            language: chinese,
            target: english,
            brief: brief
        )
    }

    func kinds(
        _ source: String,
        _ translation: String,
        brief: TranslationBrief = .none
    ) -> Set<IntegrityFinding.Kind> {
        Set(findings(source, translation, brief: brief).map(\.kind))
    }

    // A clean translation raises nothing.
    report.expect(
        findings(
            "本协议自2024年3月15日起生效，有效期为三年。",
            "This agreement takes effect on 15 March 2024 and runs for three "
                + "years."
        ).isEmpty,
        "a sound translation should raise no findings"
    )

    // The failure this whole file exists for: a fluent paragraph whose
    // figures moved.
    report.expect(
        kinds(
            "本协议自2024年3月15日起生效。",
            "This agreement takes effect on 15 March 2025."
        ).contains(.droppedNumber),
        "a changed year must be caught"
    )
    report.expect(
        kinds("罚款为5000元。", "The fine is 500 yuan.")
            .contains(.droppedNumber),
        "a dropped digit must be caught"
    )
    // Grouping and full-width forms are the same figure.
    report.expect(
        !kinds("金额为１０，０００元。", "The amount is 10,000 yuan.")
            .contains(.droppedNumber),
        "full-width and grouped digits are the same number"
    )

    report.expect(
        kinds("请在三日内答复。", "请在三日内答复。").contains(.echoedSource),
        "text handed back untranslated must be caught"
    )
    report.expect(
        kinds(
            "本公司将于下周召开股东大会讨论年度预算。",
            "The company will hold 股东大会 next week to discuss 年度预算 and "
                + "other 事项."
        ).contains(.untranslatedScript),
        "large amounts of untranslated Chinese must be caught"
    )
    report.expect(
        kinds("请勿吸烟。", "").contains(.emptyTranslation),
        "an empty translation must be caught"
    )
    report.expect(
        kinds(
            "请注意安全并遵守现场工作人员的指示。",
            "Please be careful please be careful please be careful please be "
                + "careful please be careful."
        ).contains(.repeatedRun),
        "a looping model must be caught"
    )
    report.expect(
        kinds(
            "会议将在明天上午九点开始。",
            "Here is the translation: the meeting starts at 9am tomorrow."
        ).contains(.leakedInstruction),
        "a model answering about the task must be caught"
    )

    // The brief, enforced rather than requested.
    let keepName = TranslationBrief(
        glossary: [GlossaryTerm(term: "王小明", handling: .keepAsWritten)]
    )
    report.expect(
        kinds(
            "王小明先生已签署本合同。",
            "Mr Wang Xiaoming has signed this contract.",
            brief: keepName
        ).contains(.briefIgnored),
        "a name the reader asked to keep must be reported when translated"
    )
    report.expect(
        !kinds(
            "王小明先生已签署本合同。",
            "Mr 王小明 has signed this contract.",
            brief: keepName
        ).contains(.briefIgnored),
        "keeping the name satisfies the brief"
    )
    // And keeping it must not then be reported as untranslated text.
    report.expect(
        !kinds(
            "王小明先生已签署本合同。",
            "Mr 王小明 has signed this contract.",
            brief: keepName
        ).contains(.untranslatedScript),
        "a kept term is not untranslated text"
    )

    let houseTerm = TranslationBrief(
        glossary: [GlossaryTerm(term: "公司", handling: .render("the Company"))]
    )
    report.expect(
        kinds("公司应当承担全部责任。", "The company bears full liability.",
              brief: houseTerm).contains(.briefIgnored),
        "a required rendering must be reported when it is not used"
    )

    report.begin("integrity/numbers")
    report.equal(
        TextIntegrity.numberRuns(in: "共计1,234.50元，编号No.7。"),
        ["1234.50", "7"],
        "digit runs strip grouping and keep decimals"
    )
    report.equal(
        TextIntegrity.repeatedRun(
            in: "a b c d e f g h"
        ),
        nil,
        "ordinary text is not a repetition"
    )
}
