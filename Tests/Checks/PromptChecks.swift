import DocCore
import Foundation
import LanguageChinese

/// Reading what a model said, including when it did not follow the form.
func runPromptChecks(_ report: Report) {
    report.begin("prompts/verdict")

    report.expect(
        AgentPrompts.verdict(from: "VERDICT: ACCURATE").isAccurate,
        "an approval is read as an approval"
    )
    report.equal(
        AgentPrompts.verdict(from: "VERDICT: ACCURATE").revision,
        nil,
        "an approval carries no revision"
    )

    let revised = AgentPrompts.verdict(
        from: """
            VERDICT: REVISE
            REVISION: The contract runs for five years.
            """
    )
    report.expect(!revised.isAccurate, "a revision is not an approval")
    report.equal(
        revised.revision,
        "The contract runs for five years.",
        "the revision is recovered"
    )

    // The failure that matters: a model that says REVISE and then supplies
    // nothing must not blank the translation.
    let empty = AgentPrompts.verdict(from: "VERDICT: REVISE\nREVISION:")
    report.equal(
        empty.revision,
        nil,
        "an empty revision is no revision, not an empty translation"
    )
    let silent = AgentPrompts.verdict(from: "VERDICT: REVISE")
    report.equal(
        silent.revision,
        nil,
        "a verdict with no revision does not overwrite the draft"
    )
    report.expect(
        AgentPrompts.verdict(from: "Looks fine to me.").isAccurate,
        "an answer that ignores the form is treated as approval"
    )

    report.begin("prompts/questions")

    let questions = AgentPrompts.questions(
        from: """
            QUESTION: Is this a contract or a notice?
            BECAUSE: 本协议
            OPTION: A contract | Use contractual register.
            OPTION: A notice | Use plain register.

            QUESTION: Who is 对方?
            OPTION: A company | Translate as "the other party".
            OPTION: A person | Translate as "the other person".
            """
    )
    report.equal(questions.count, 2, "both questions are read")
    report.equal(
        questions.first?.evidence,
        "本协议",
        "the phrase that raised the question is kept"
    )
    report.equal(
        questions.first?.options.count,
        3,
        "the reader's own “I'm not sure” is always offered"
    )
    report.equal(
        questions.first?.options.last?.label,
        ClarificationOption.unsure.label,
        "and it is offered last"
    )

    report.expect(
        AgentPrompts.questions(from: "NONE").isEmpty,
        "a model with nothing to ask asks nothing"
    )
    report.expect(
        AgentPrompts.questions(
            from: "QUESTION: Something?\nOPTION: only one | do this."
        ).isEmpty,
        "a question with one option is not a question"
    )
    report.equal(
        AgentPrompts.questions(
            from: (1...6).map {
                """
                QUESTION: Question \($0)?
                OPTION: A | do a.
                OPTION: B | do b.
                """
            }.joined(separator: "\n"),
            limit: 3
        ).count,
        3,
        "the reader is never asked more than three things"
    )

    report.begin("prompts/brief")
    let brief = TranslationBrief(
        instructions: ["Keep personal names in Chinese."],
        glossary: [GlossaryTerm(term: "公司", handling: .render("the Company"))]
    )
    let instructions = AgentPrompts.translationInstructions(
        languages: SimplifiedChinese.toEnglish,
        brief: brief
    )
    report.expect(
        instructions.contains("Keep personal names in Chinese."),
        "the reader's instruction reaches the translator"
    )
    report.expect(
        instructions.contains("the Company"),
        "a glossary rendering reaches the translator"
    )
    // The reviewer has to know what was asked, or it will approve a
    // translation that ignored it.
    report.expect(
        AgentPrompts.reviewInstructions(
            languages: SimplifiedChinese.toEnglish,
            brief: brief
        ).contains("Keep personal names in Chinese."),
        "the reviewer is told what the reader asked for"
    )

    report.begin("prompts/fences")
    report.equal(
        AgentPrompts.stripFences("```\n合同期限为三年。\n```"),
        "合同期限为三年。",
        "code fences are removed"
    )
}
