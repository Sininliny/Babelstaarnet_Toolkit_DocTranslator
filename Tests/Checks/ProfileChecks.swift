import DocAgents
import DocCore
import Foundation
import LanguageChinese

/// Reading the whole document before translating a sentence of it.
///
/// The thing being checked here is the one defect a sentence-at-a-time
/// translator has that none of the other checks in this project can see: every
/// block is defensible on its own line and the document still reads as though
/// two people produced it. So these checks are mostly about whether what the
/// document decided actually reaches the stages that only ever see one block.
func runProfileChecks(_ report: Report) async {
    report.begin("profile/parsing")

    let profile = AgentPrompts.profile(
        from: """
            KIND: a court enforcement notice
            SUBJECT: an order to pay a judgment debt
            REGISTER: formal legal
            TERM: 被执行人 | the person subject to enforcement
            TERM: 申请执行人 | the applicant for enforcement
            NOTE: 本院 refers to the issuing court, not the reader.
            """
    )
    report.equal(profile.kind, "a court enforcement notice", "the kind is read")
    report.equal(profile.register, "formal legal", "the register is read")
    report.equal(profile.terms.count, 2, "both terms are read")
    report.equal(
        profile.terms["被执行人"],
        "the person subject to enforcement",
        "and mapped to their agreed rendering"
    )
    report.equal(profile.notes.count, 1, "the note is read")
    report.expect(!profile.isEmpty, "a profile with content is not empty")

    // The guidance is stable between runs. A prompt that varies with
    // dictionary order makes two runs of the same document differ for no
    // reason anyone can see.
    report.equal(
        profile.guidanceLines(),
        profile.guidanceLines(),
        "the guidance is in a fixed order"
    )
    report.equal(
        profile.termLines(appearingIn: "被执行人与申请执行人均应到庭。").count,
        2,
        "and so are the agreed terms"
    )
    report.expect(
        profile.guidanceLines().allSatisfy { !$0.contains("被执行人") },
        "the terms are not repeated in front of every block"
    )

    // Only the terms in the block, so a glossary of eight does not sit in
    // front of every sentence.
    report.equal(
        profile.terms(appearingIn: "被执行人应当履行义务。").count,
        1,
        "only the terms that occur in a block are passed with it"
    )
    report.expect(
        profile.terms(appearingIn: "本通知自即日起生效。").isEmpty,
        "and none where none occur"
    )

    report.expect(
        AgentPrompts.profile(from: "I could not read this.").isEmpty,
        "an answer that ignores the form yields no profile"
    )

    report.begin("profile/prompts")
    let instructions = AgentPrompts.translationInstructions(
        languages: SimplifiedChinese.toEnglish,
        profile: profile
    )
    report.expect(
        instructions.contains("court enforcement notice"),
        "the translator is told what the document is"
    )
    report.expect(
        instructions.contains("formal legal"),
        "and how it is meant to sound"
    )
    report.expect(
        AgentPrompts.reviewInstructions(
            languages: SimplifiedChinese.toEnglish,
            profile: profile,
            agreedTerms: profile.termLines(
                appearingIn: "被执行人应当履行义务。"
            )
        ).contains("the person subject to enforcement"),
        "and the reviewer is told what this block's terms are already called"
    )
    report.expect(
        !AgentPrompts.reviewInstructions(
            languages: SimplifiedChinese.toEnglish,
            profile: profile,
            agreedTerms: profile.termLines(appearingIn: "本通知生效。")
        ).contains("the person subject to enforcement"),
        "and not about the terms this block does not contain"
    )

    report.begin("profile/context")
    let prompt = AgentPrompts.translationPrompt(
        text: "该方应当在三十日内答复。",
        kind: .paragraph,
        documentContext: nil,
        following: TranslationContext(
            previousSource: "甲方为北京安泰科技有限公司。",
            previousTarget: "Party A is Beijing Antai Technology Co., Ltd."
        )
    )
    report.expect(
        prompt.contains("Party A is Beijing Antai"),
        "the previous translation is carried forward, so a term stays itself"
    )
    report.expect(
        prompt.contains("Translate only what follows"),
        "and the model is told which part to translate"
    )
    report.expect(
        !AgentPrompts.translationPrompt(
            text: "该方应当在三十日内答复。",
            kind: .paragraph,
            documentContext: nil
        ).contains("previous sentence"),
        "with no context, nothing is invented"
    )

    await runSurveyChecks(report)
    runConsistencyChecks(report, profile: profile)
}

/// What the profile is built from: text taken across the document rather than
/// off the front of it.
private func runSurveyChecks(_ report: Report) async {
    report.begin("profile/survey")

    // Spread, and always ending on the last page. A contract says who the
    // parties are on page one and what they agreed at the end.
    let spread = DocumentSurvey.surveyPages(of: 20, limit: 2)
    report.equal(spread, [10, 19], "two picks land in the middle and at the end")
    report.expect(
        !spread.contains(1),
        "and not on the page after the opening, which the opening covers"
    )
    report.equal(
        DocumentSurvey.surveyPages(of: 4, limit: 12),
        [1, 2, 3],
        "a short document is sampled whole"
    )
    report.equal(
        DocumentSurvey.surveyPages(of: 1, limit: 12),
        [],
        "and a one-page document has nothing else to sample"
    )
    report.equal(
        DocumentSurvey.surveyPages(of: 20, limit: 1),
        [19],
        "one pick is spent on the end of the document"
    )

    let language = SimplifiedChinese.toEnglish.source
    let opening = [
        reconciled("北京市朝阳区人民法院执行通知书，案号（2024）京0105执12345号。"),
        reconciled("被执行人：王小明。申请执行人：北京安泰科技有限公司。")
    ]

    // A PDF that carries its own text: the whole document is free to read, so
    // the survey reaches the end of it.
    var borndigital = BlankPages(pageCount: 9)
    for page in 1..<9 {
        borndigital.layers[page] = PageReading(
            reader: .pdfTextLayer,
            pageIndex: page,
            blocks: [block("第\(page + 1)页的内容：逾期未履行的，本院将依法强制执行。")]
        )
    }
    let free = await DocumentSurvey(
        provider: borndigital,
        language: language
    ).sample(openingWith: opening)
    report.expect(
        free.contains("第9页的内容"),
        "the survey reads to the end of a document that carries its own text"
    )
    report.expect(
        free.contains("[page 1]") && free.contains("[page 9]"),
        "and marks which page each part came from, because it is not prose"
    )
    report.expect(
        free.contains("王小明"),
        "the opening the pipeline already read is not read again, and is kept"
    )
    report.expect(
        free.count <= DocumentSurvey.sampleLimit,
        "the whole sample stays inside one model call"
    )

    // A scan: every page costs a recognition, so the survey is rationed — and
    // spends what it has on the parts of the document the opening did not
    // already cover.
    let scan = BlankPages(pageCount: 9)
    let quick = ScriptedReader(
        reader: .visionOCR,
        pages: Dictionary(
            uniqueKeysWithValues: (1..<9).map {
                ($0, [block("第\($0 + 1)页：本院将依法强制执行并加倍支付利息。")])
            }
        )
    )
    let rationed = await DocumentSurvey(
        provider: scan,
        language: language,
        reader: quick
    ).sample(openingWith: opening)
    report.expect(
        rationed.contains("第9页"),
        "a scan is still sampled at its end"
    )
    report.expect(
        !rationed.contains("第2页") && !rationed.contains("第3页"),
        "but not page by page — recognition is rationed to two pages"
    )

    // With no reader quick enough, the survey does not spend twenty seconds a
    // page proving it. It profiles from what it already has.
    let unread = await DocumentSurvey(
        provider: scan,
        language: language,
        reader: nil
    ).sample(openingWith: opening)
    report.expect(
        unread.contains("王小明") && !unread.contains("第9页"),
        "and with no quick reader the survey is the opening alone"
    )
    report.expect(
        await DocumentSurvey(
            provider: BlankPages(pageCount: 1),
            language: language
        ).sample(openingWith: []).isEmpty,
        "a document with nothing read on it surveys to nothing"
    )
}

/// The mechanical half: a rendering that disagrees with the rest of the
/// document is a defect, and no model in this pipeline can see it.
private func runConsistencyChecks(_ report: Report, profile: DocumentProfile) {
    report.begin("profile/consistency")
    let languages = SimplifiedChinese.toEnglish

    func findings(
        _ translation: String,
        brief: TranslationBrief = .none
    ) -> [IntegrityFinding] {
        TextIntegrity.check(
            source: "被执行人应当在收到本通知之日起3日内履行义务。",
            translation: translation,
            language: languages.source,
            target: languages.target,
            brief: brief,
            profile: profile
        )
    }

    let agreed = findings(
        "Within 3 days of receiving this notice, the person subject to "
            + "enforcement shall perform the obligation."
    )
    report.expect(
        !agreed.contains { $0.kind == .inconsistentTerm },
        "a block that uses the document's own rendering is not flagged"
    )

    let drifted = findings(
        "Within 3 days of receiving this notice, the judgment debtor shall "
            + "perform the obligation."
    )
    report.expect(
        drifted.contains { $0.kind == .inconsistentTerm },
        "and one that quietly renames the party is"
    )
    report.expect(
        drifted.allSatisfy { $0.severity != .blocking },
        "as a caution, not a failure: this is the app's reading, not yours"
    )

    // The reader outranks the app. A block doing exactly what the brief asked
    // must not then be marked for disagreeing with the app's own guess.
    let yours = TranslationBrief(
        glossary: [
            GlossaryTerm(
                term: "被执行人",
                handling: .render("the judgment debtor")
            )
        ]
    )
    let told = findings(
        "Within 3 days of receiving this notice, the judgment debtor shall "
            + "perform the obligation.",
        brief: yours
    )
    report.expect(
        !told.contains { $0.kind == .inconsistentTerm },
        "your own instruction beats the app's reading of the document"
    )
    report.expect(
        !told.contains { $0.kind == .briefIgnored },
        "and following it is not a finding either"
    )

    report.expect(
        TextIntegrity.check(
            source: "本通知自即日起生效。",
            translation: "This notice takes effect immediately.",
            language: languages.source,
            target: languages.target,
            profile: profile
        ).isEmpty,
        "a block containing none of the agreed terms is checked as before"
    )
}

/// A reconciled block, briefly — the shape the pipeline hands the survey.
private func reconciled(_ text: String) -> ReconciledBlock {
    ReconciledBlock(
        pageIndex: 0,
        order: 0,
        box: .full,
        kind: .paragraph,
        text: text,
        candidates: [.visionOCR: text],
        agreement: 1,
        settlement: .unanimous
    )
}
