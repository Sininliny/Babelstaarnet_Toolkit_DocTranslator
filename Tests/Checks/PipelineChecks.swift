import DocAgents
import DocCore
import Foundation
import LanguageChinese

/// A model that plays all three text roles from a script.
///
/// It has to tell them apart the way a real model does — from the prompt — so
/// the check exercises the prompts as well as the pipeline.
private func scriptedTextAgent(
    english: [String: String],
    questions: String = AgentPrompts.noQuestionsMarker
) -> ScriptedAgent {
    ScriptedAgent { prompt, _ in
        if prompt.contains("beginning of the document") {
            return questions
        }
        if prompt.contains("Translate this") {
            let source = prompt
                .components(separatedBy: "\n")
                .last?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return english[source] ?? source
        }
        return AgentPrompts.verdictMarker + " " + AgentPrompts.verdictAccurate
    }
}

/// Somewhere to put a value a concurrent closure writes.
private final class Counter: @unchecked Sendable {
    var value = 0
}

/// The whole chain, end to end, with no Vision and no model.
func runPipelineChecks(_ report: Report) async {
    report.begin("pipeline")
    let languages = SimplifiedChinese.toEnglish

    let sources = [
        "本协议由甲乙双方于2024年3月15日在北京签订。",
        "合同期限为三年，逾期未付款的罚款为5000元。"
    ]
    let english = [
        sources[0]:
            "This agreement was signed in Beijing by both parties on "
            + "15 March 2024.",
        sources[1]:
            "The contract runs for three years, and the penalty for late "
            + "payment is 5000 yuan."
    ]

    func reader(_ kind: PageReader) -> ScriptedReader {
        ScriptedReader(
            reader: kind,
            pages: [
                0: sources.enumerated().map { index, text in
                    block(text, order: index, y: 0.1 + Double(index) * 0.1)
                }
            ]
        )
    }

    let ocr = reader(.visionOCR)
    let model = reader(.visionLanguageModel)
    let translator = ScriptedTranslator { english[$0] ?? "" }
    let agent = scriptedTextAgent(english: english)

    func engines(
        translating: ScriptedTranslator = translator,
        agent: ScriptedAgent
    ) -> Engines {
        Engines(
            readers: [ocr, model],
            textAgent: agent,
            machineTranslator: translating,
            preference: .fastest
        )
    }

    let document = try? await TranslationPipeline(
        languages: languages,
        engines: engines(agent: agent)
    ).run(BlankPages(pageCount: 1))

    report.expect(document != nil, "the pipeline produces a document")
    report.equal(document?.blocks.count, 2, "both blocks come through")
    report.equal(
        document?.blocks.first?.text,
        english[sources[0]],
        "the translation reaches the document"
    )
    report.expect(
        document?.needingAttention.isEmpty == true,
        "a clean run flags nothing: "
            + (document?.needingAttention.first?.confidence.reasons
                .joined(separator: "; ") ?? "")
    )
    report.expect(
        document?.blocks.allSatisfy { $0.confidence.band == .high } == true,
        "agreed, translated and reviewed blocks score high"
    )
    report.expect(
        document?.engines.readers.count == 2,
        "the document records that two readers read it"
    )

    report.begin("pipeline/failures")

    // A translator that drops the figure must not produce a confident block,
    // however happily the reviewer approved it.
    let dropping = ScriptedTranslator { source in
        source == sources[1]
            ? "The contract runs for three years, and the penalty for late "
                + "payment is 500 yuan."
            : english[source] ?? ""
    }
    let damaged = try? await TranslationPipeline(
        languages: languages,
        engines: engines(translating: dropping, agent: agent)
    ).run(BlankPages(pageCount: 1))
    let fine = damaged?.blocks.first { $0.source.text.contains("5000") }
    report.expect(
        fine?.findings.contains { $0.kind == .droppedNumber } == true,
        "a dropped figure is found even though the reviewer approved"
    )
    report.expect(
        fine?.confidence.band == .low,
        "a block with a dropped figure needs a human"
    )
    report.expect(
        damaged?.needingAttention.isEmpty == false,
        "the document lists what needs a human"
    )

    // No translator at all is an error, not an empty document.
    let none = try? await TranslationPipeline(
        languages: languages,
        engines: Engines(readers: [ocr])
    ).run(BlankPages(pageCount: 1))
    report.expect(none == nil, "a run with no translator fails loudly")

    report.begin("pipeline/brief")

    let name = "王小明先生已签署本合同，其住所位于北京市朝阳区。"
    let named = ScriptedReader(
        reader: .visionOCR,
        pages: [0: [block(name, order: 0)]]
    )
    let namedModel = ScriptedReader(
        reader: .visionLanguageModel,
        pages: [0: [block(name, order: 0)]]
    )
    let ignored = "Mr Wang Xiaoming has signed this contract; he lives in "
        + "Chaoyang District, Beijing."
    let ignoring = ScriptedTranslator { _ in ignored }
    let brief = TranslationBrief(
        instructions: ["Keep personal names in Chinese."],
        glossary: [GlossaryTerm(term: "王小明", handling: .keepAsWritten)]
    )
    let briefed = try? await TranslationPipeline(
        languages: languages,
        engines: Engines(
            readers: [named, namedModel],
            textAgent: scriptedTextAgent(english: [name: ignored]),
            machineTranslator: ignoring,
            preference: .fastest
        )
    ).run(BlankPages(pageCount: 1), brief: brief)
    report.expect(
        briefed?.blocks.first?.findings.contains {
            $0.kind == .briefIgnored
        } == true,
        "an ignored instruction is reported, not silently accepted"
    )
    report.expect(
        briefed?.blocks.first?.confidence.band == .low,
        "and the block is marked for a human"
    )

    // A brief is only a brief if the translator that leads can read one. The
    // dedicated translation model cannot take an instruction at all, so a
    // non-empty brief has to move the language model into the lead whatever
    // the speed preference says — otherwise turning on "fastest" would
    // silently discard everything the reader asked for.
    let leading = try? await TranslationPipeline(
        languages: languages,
        engines: Engines(
            readers: [named, namedModel],
            textAgent: scriptedTextAgent(english: [name: "from the model"]),
            machineTranslator: ScriptedTranslator { _ in "from the machine" },
            preference: .fastest
        )
    ).run(BlankPages(pageCount: 1), brief: brief)
    report.equal(
        leading?.blocks.first?.firstDraft,
        "from the model",
        "a brief puts the instruction-following translator in the lead"
    )

    let noBrief = try? await TranslationPipeline(
        languages: languages,
        engines: Engines(
            readers: [named, namedModel],
            textAgent: scriptedTextAgent(english: [name: "from the model"]),
            machineTranslator: ScriptedTranslator { _ in "from the machine" },
            preference: .fastest
        )
    ).run(BlankPages(pageCount: 1))
    report.equal(
        noBrief?.blocks.first?.firstDraft,
        "from the machine",
        "and with nothing asked for, the preference decides"
    )

    report.begin("pipeline/questions")

    // The clarification handshake: the pipeline parks, the answer arrives,
    // and the run continues with it.
    let asking = scriptedTextAgent(
        english: english,
        questions: """
            \(AgentPrompts.questionMarker) Is 甲乙双方 a company or a person?
            \(AgentPrompts.evidenceMarker) 由甲乙双方
            \(AgentPrompts.optionMarker) Companies | Translate 甲乙双方 as \
            "the two parties".
            \(AgentPrompts.optionMarker) People | Translate 甲乙双方 as \
            "the two signatories".
            """
    )

    let asked = Counter()
    let answered = try? await TranslationPipeline(
        languages: languages,
        engines: engines(agent: asking)
    ).run(
        BlankPages(pageCount: 1),
        clarify: { questions in
            asked.value = questions.count
            return questions.compactMap { question in
                guard let option = question.options.first else { return nil }
                return SettledQuestion(
                    question: question.question,
                    answer: option.label,
                    guidance: option.guidance
                )
            }
        }
    )
    report.equal(asked.value, 1, "the reader is asked the model's question")
    report.expect(answered != nil, "the run finishes after being answered")

    // A reader who is not asked still gets a translation.
    let unasked = try? await TranslationPipeline(
        languages: languages,
        engines: engines(agent: asking)
    ).run(BlankPages(pageCount: 1), clarify: nil)
    report.expect(unasked != nil, "a run with no questions finishes")

    report.begin("pipeline/text layer")

    // A born-digital PDF settles its own text and needs no adjudication —
    // the reader must never be asked to arbitrate a document that came with
    // its own words.
    var withLayer = BlankPages(pageCount: 1)
    withLayer.layers = [
        0: PageReading(
            reader: .pdfTextLayer,
            pageIndex: 0,
            blocks: [block(sources[0], order: 0)]
        )
    ]
    let refusing = ScriptedAgent { prompt, _ in
        if prompt.contains("Which is closer to what is printed") {
            throw AgentFailure.refused(
                "a text layer must not need an adjudicator"
            )
        }
        if prompt.contains("Translate this") { return english[sources[0]] ?? "" }
        return AgentPrompts.verdictMarker + " " + AgentPrompts.verdictAccurate
    }
    let digital = try? await TranslationPipeline(
        languages: languages,
        engines: Engines(
            readers: [
                ScriptedReader(
                    reader: .visionOCR,
                    pages: [0: [block("本协议由甲乙双方于2O24年3月15日在北京签订。", order: 0)]]
                )
            ],
            textAgent: refusing,
            machineTranslator: translator,
            preference: .fastest
        )
    ).run(withLayer)
    report.equal(
        digital?.blocks.first?.source.settlement,
        .textLayer,
        "the PDF's own text settles the block"
    )
    report.equal(
        digital?.blocks.first?.source.text,
        sources[0],
        "and the misread OCR digit does not survive"
    )
}
