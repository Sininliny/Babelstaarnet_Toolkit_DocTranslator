import DocAgents
import DocCore
import Foundation
import LanguageChinese

/// What the translator is shown besides the block it is translating.
///
/// The unit is the sentence and the context is the document, and between
/// those two there is a third question this file is about: how much of the
/// page immediately around a block that block actually needs. Both wrong
/// answers are cheap to write and expensive to run. Give every block
/// everything and a four-character heading arrives wrapped in four hundred
/// characters of prose, which is the reliable way to make a small model
/// translate the context instead of the block. Give every block nothing and
/// 该方 becomes "the said party" on a page where the party was named one line
/// earlier.
func runContextChecks(_ report: Report) async {
    let chinese = SimplifiedChinese.language

    func need(
        _ text: String,
        kind: BlockKind = .paragraph,
        _ context: TranslationContext
    ) -> ContextNeed {
        AdaptiveContext.need(
            for: text,
            kind: kind,
            available: context,
            language: chinese
        )
    }

    report.begin("context/floor")

    let settled = TranslationContext(
        previousSource: "甲方为北京安泰科技有限公司，乙方为王小明。",
        previousTarget: "Party A is Beijing Antai Technology Co., Ltd. and "
            + "Party B is Wang Xiaoming."
    )

    // A sentence that stands on its own is translated on its own — with one
    // exception, and the exception is the cheap half: the English of the line
    // before it, which is what keeps a recurring term rendered the same way
    // twenty sentences apart.
    let standsAlone = need(
        "本协议自双方签字之日起生效，有效期为三年，期满后可以续签。",
        settled
    )
    report.expect(
        standsAlone.previousTarget,
        "a self-contained block still sees the English of the line before it"
    )
    report.expect(
        !standsAlone.previousSource,
        "but not its Chinese, which is the half a model translates by mistake"
    )
    report.expect(
        !standsAlone.wasWidened,
        "and nothing else: a sentence that stands alone is translated alone"
    )

    report.expect(
        need("本协议自双方签字之日起生效。", .none).isEmpty,
        "the first block of a document has nothing around it"
    )
    report.expect(
        need("第 3 页", kind: .pageFurniture, settled).isEmpty,
        "page furniture is never translated, so it is never given context"
    )

    report.begin("context/widening")

    // A block that points outside itself is shown what it points at. 该方 is
    // the case: on its own it is "the said party", and one line up it has a
    // name.
    let refers = need("该方应当在三十日内答复。", settled)
    report.expect(
        refers.previousSource,
        "a block referring to something outside itself sees the line before"
    )
    report.expect(
        !refers.reasons.isEmpty,
        "and says why, because a widened context is part of the working"
    )

    // A block that continues one. The signal is on the *previous* block: it
    // did not end at a sentence stop, so this one is the rest of it.
    let unfinished = TranslationContext(
        previousSource: "本院经审查认为，被执行人未按期履行生效法律文书确定的义务",
        previousTarget: "This court finds that the person subject to "
            + "enforcement has not performed the obligation"
    )
    report.expect(
        need("依法应当强制执行其名下财产。", unfinished).previousSource,
        "a block whose predecessor did not finish is shown the whole of it"
    )
    report.expect(
        need("但是逾期利息应当另行计算。", settled).previousSource,
        "and so is one that opens with a word that only continues something"
    )

    // 应该 is "ought to" and contains 该, which is the strongest referring
    // cue there is. Without the false-friend list this fires on roughly every
    // obligation in an official document, and a rule that fires on every
    // block is the rule that was not written.
    report.expect(
        !need(
            "承包方应该按照约定的期限完成全部施工任务并交付使用。",
            settled
        ).previousSource,
        "“应该” is not a reference to something outside the sentence"
    )

    report.begin("context/direction")

    // A heading is named by the section under it, not by itself. 执行 is
    // "enforcement" over a court order and "execution" over a build script,
    // and nothing in the heading decides which.
    let section = TranslationContext(
        previousSource: "北京市朝阳区人民法院执行通知书",
        previousTarget: "Beijing Chaoyang District People's Court "
            + "enforcement notice",
        nextSource: "被执行人应当自收到本通知之日起三日内履行生效法律文书确定的义务。"
    )
    let heading = need("执行事项", kind: .heading, section)
    report.expect(
        heading.following,
        "a heading is shown what comes under it"
    )
    report.expect(
        heading.reasons.contains { $0.contains("section") },
        "and the reason names why"
    )
    report.expect(
        !need(
            "被执行人应当自收到本通知之日起三日内履行生效法律文书确定的义务。",
            section
        ).following,
        "an ordinary sentence is not shown the one after it"
    )

    // An item under a stem. On a form this is most of the page: a cell
    // reading 3 means nothing at all, and the column heading above it is the
    // whole content of the block.
    let inATable = TranslationContext(
        previousSource: "项目",
        previousTarget: "Item",
        nextSource: "0-450",
        sectionHeading: "Test results"
    )
    report.expect(
        need("68.4", kind: .tableRow, inATable).heading,
        "a row of a table is shown the heading it sits under"
    )
    report.expect(
        !need(
            "本报告仅对本次送检样品负责，未经许可不得部分复制。",
            TranslationContext(
                previousSource: "检测结论：合格。",
                previousTarget: "Conclusion: pass.",
                sectionHeading: "Test results"
            )
        ).heading,
        "and a paragraph that says what it means is not"
    )

    report.begin("context/prompt")

    // The prompt spends exactly what the need asked for. This is the check
    // that matters: a need computed correctly and then ignored by the prompt
    // builder would leave no other trace.
    let widened = AgentPrompts.translationPrompt(
        text: "该方应当在三十日内答复。",
        kind: .paragraph,
        documentContext: nil,
        following: settled,
        need: refers
    )
    report.expect(
        widened.contains("甲方为北京安泰科技"),
        "what was asked for is in the prompt"
    )
    let narrow = AgentPrompts.translationPrompt(
        text: "本协议自双方签字之日起生效，有效期为三年，期满后可以续签。",
        kind: .paragraph,
        documentContext: nil,
        following: settled,
        need: standsAlone
    )
    report.expect(
        !narrow.contains("甲方为北京安泰科技"),
        "and what was not asked for is not"
    )
    report.expect(
        narrow.contains("Party A is Beijing Antai"),
        "the English half still is"
    )
    report.expect(
        narrow.hasSuffix("本协议自双方签字之日起生效，有效期为三年，期满后可以续签。"),
        "the block to translate is last, where a model cannot mistake it"
    )
    report.expect(
        AgentPrompts.translationPrompt(
            text: "68.4",
            kind: .tableRow,
            documentContext: nil,
            following: inATable,
            need: need("68.4", kind: .tableRow, inATable)
        ).contains("Test results"),
        "and a cell arrives under its column heading"
    )

    report.begin("context/reasoning")

    // A thinking model's reasoning is not a translation, and left in it is
    // what gets drawn onto the page.
    report.equal(
        AgentPrompts.stripWrapping(
            "<think>The user wants me to render 甲方. Party A is standard."
                + "</think>\nParty A shall pay the sum."
        ),
        "Party A shall pay the sum.",
        "a reasoning block is removed, answer and all"
    )
    report.equal(
        AgentPrompts.stripWrapping(
            "I should think about this.</think>Party A shall pay the sum."
        ),
        "Party A shall pay the sum.",
        "including where the template opened the block for the model"
    )
    report.equal(
        AgentPrompts.stripWrapping("<think>Still thinking about the register"),
        "",
        "a model that only ever reasoned answered nothing, and says so"
    )
    report.equal(
        AgentPrompts.stripWrapping("```\nParty A shall pay.\n```"),
        "Party A shall pay.",
        "and the fences still come off"
    )

    await runRetryChecks(report)
    await runContextPipelineChecks(report)
}

/// The same thing end to end: does the page around a block actually reach the
/// translator when the pipeline is the one assembling it?
///
/// The unit checks above are about a decision. This one is about plumbing,
/// and plumbing is where this stage would fail silently — a need computed
/// perfectly on a context nobody filled in produces exactly the prompts the
/// app had before any of this existed.
private func runContextPipelineChecks(_ report: Report) async {
    report.begin("context/pipeline")
    let languages = SimplifiedChinese.toEnglish

    let heading = "执行事项"
    let item = "该项应当在三十日内履行完毕。"
    let english = [
        heading: "Enforcement matters",
        item: "That item shall be performed within thirty days."
    ]

    let recorder = Recorder()
    let agent = ScriptedAgent { instructions, prompt, _ in
        if instructions.contains("read it and say what it is") {
            return "I have nothing to say about this document."
        }
        if prompt.contains("Translate this") {
            recorder.append(instructions: instructions, prompt: prompt)
            let source = prompt
                .components(separatedBy: "\n")
                .last?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return english[source] ?? source
        }
        return AgentPrompts.verdictMarker + " " + AgentPrompts.verdictAccurate
    }

    let reader = ScriptedReader(
        reader: .visionOCR,
        pages: [
            0: [
                block(heading, order: 0, kind: .heading, y: 0.1),
                block(item, order: 1, kind: .listItem, y: 0.2)
            ]
        ]
    )

    let document = try? await TranslationPipeline(
        languages: languages,
        engines: Engines(
            readers: [reader],
            textAgent: agent,
            preference: .followsInstructions
        )
    ).run(BlankPages(pageCount: 1))

    report.expect(document != nil, "the pipeline runs")

    // The heading was translated first, and it was given the line under it —
    // which is the only thing on the page that says what kind of "執行" this
    // is.
    let headingCall = recorder.translating(heading)
    report.expect(
        headingCall?.prompt.contains(item) == true,
        "the heading is translated knowing what its section says"
    )

    // And the item under it was given the heading, in English, because the
    // pipeline had already translated it.
    let itemCall = recorder.translating(item)
    report.expect(
        itemCall?.prompt.contains("Enforcement matters") == true,
        "and the item under it is translated knowing which heading it is under"
    )
    report.expect(
        itemCall?.prompt.contains("It sits under the heading") == true,
        "labelled as context rather than dropped in front of the block"
    )
    report.expect(
        document?.blocks.last?.context.wasWidened == true,
        "and the document records that this block was given more than the rest"
    )
    report.expect(
        document?.blocks.last?.context.reasons.isEmpty == false,
        "with the reasons, so the side-by-side can show them"
    )
}


/// A block handed back untranslated, tried again with nothing around it.
///
/// The measurement behind this is in `ContextNeed.retriedAlone`: put to a 3B,
/// a numbered item that is mostly figures comes back as its own source about
/// one time in five when anything is placed in front of it, and never when
/// nothing is. The rule is triggered by the mechanical check rather than
/// decided in advance, so what is checked here is that the trigger works and
/// that it does not fire on a block that was fine.
private func runRetryChecks(_ report: Report) async {
    report.begin("context/retry")
    let languages = SimplifiedChinese.toEnglish
    let figures = "一、支付货款人民币580000元及利息23400元；"

    // A model that copies the source back whenever it is shown context,
    // which is what the real one does on a block like this about one time in
    // five.
    let agent = ScriptedAgent { instructions, prompt, _ in
        if instructions.contains("check a translation") {
            return AgentPrompts.verdictMarker + " "
                + AgentPrompts.verdictAccurate
        }
        // Copies the source back when there is anything in front of the
        // block, and translates when there is not.
        if prompt.contains("The line before") {
            return figures
        }
        return "1. Pay 580000 yuan for the goods and 23400 yuan in interest;"
    }

    let block = ReconciledBlock(
        pageIndex: 0,
        order: 1,
        box: .full,
        kind: .listItem,
        text: figures,
        candidates: [.visionOCR: figures],
        agreement: nil,
        settlement: .single(.visionOCR)
    )
    let context = TranslationContext(
        previousSource: "限你于收到本通知之日起3日内履行下列义务：",
        previousTarget: "You are required to perform the following "
            + "obligations within three days of receiving this notice:"
    )

    let translated = await BlockTranslator(
        languages: languages,
        translator: TextAgentTranslator(agent: agent),
        reviewer: agent
    ).translate(block, following: context)

    report.expect(
        translated.context.retriedAlone,
        "a block handed back as its own source is translated again alone"
    )
    report.expect(
        !translated.text.contains("支付货款"),
        "and the second answer is the one kept: " + translated.text
    )
    report.expect(
        !translated.findings.contains {
            $0.kind == .echoedSource || $0.kind == .untranslatedScript
        },
        "so the block no longer reads as untranslated"
    )
    report.expect(
        !translated.context.reasons.isEmpty,
        "with the reason recorded, because it is part of the working"
    )

    // A translator that always copies is not saved by trying twice, and the
    // finding must survive rather than be spent on a wasted call.
    let hopeless = ScriptedAgent { instructions, _, _ in
        if instructions.contains("check a translation") {
            return AgentPrompts.verdictMarker + " "
                + AgentPrompts.verdictAccurate
        }
        return figures
    }
    let unsaved = await BlockTranslator(
        languages: languages,
        translator: TextAgentTranslator(agent: hopeless)
    ).translate(block, following: context)
    report.expect(
        unsaved.findings.contains {
            $0.kind == .echoedSource || $0.kind == .untranslatedScript
        },
        "a translator that always copies is still reported"
    )
    report.expect(
        !unsaved.context.retriedAlone,
        "and the retry is not claimed when it did not help"
    )

    // A block that came back translated is never asked twice.
    let fine = await BlockTranslator(
        languages: languages,
        translator: TextAgentTranslator(
            agent: ScriptedAgent { _, _, _ in
                "1. Pay 580000 yuan for the goods and 23400 yuan in interest;"
            }
        )
    ).translate(block, following: context)
    report.expect(
        !fine.context.retriedAlone,
        "a block that translated the first time is not translated again"
    )
}
