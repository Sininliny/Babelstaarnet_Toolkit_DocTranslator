import DocAgents
import DocCore
import Foundation
import LanguageChinese

/// What happens when the readers disagree.
func runReconcilerChecks(_ report: Report) async {
    report.begin("reconciler")
    let chinese = SimplifiedChinese.language

    func reading(
        _ reader: PageReader,
        _ texts: [String]
    ) -> PageReading {
        PageReading(
            reader: reader,
            pageIndex: 0,
            blocks: texts.enumerated().map { index, text in
                block(text, order: index, y: 0.1 + Double(index) * 0.1)
            }
        )
    }

    let agreed = ["合同期限为三年。", "自签订之日起计算。"]

    // Agreement needs no model at all.
    let unanimous = await Reconciler(
        language: chinese,
        adjudicator: ScriptedAgent { _, _ in
            throw AgentFailure.refused("the adjudicator must not be called")
        }
    ).reconcile(
        readings: [
            reading(.visionOCR, agreed),
            reading(.visionLanguageModel, agreed)
        ],
        pageIndex: 0
    )
    report.equal(unanimous.count, 2, "two agreeing readers give two blocks")
    report.equal(
        unanimous.first?.settlement,
        .unanimous,
        "identical readings are unanimous"
    )
    report.equal(unanimous.first?.agreement, 1, "agreement is total")

    // A disagreement goes to the adjudicator, and its choice is the text.
    let adjudicated = await Reconciler(
        language: chinese,
        adjudicator: ScriptedAgent.always("B")
    ).reconcile(
        readings: [
            reading(.visionOCR, ["合同期限为三年。"]),
            reading(.visionLanguageModel, ["合同期限为五年。"])
        ],
        pageIndex: 0
    )
    report.equal(
        adjudicated.first?.text,
        "合同期限为五年。",
        "the adjudicator's choice becomes the text"
    )
    report.expect(
        adjudicated.first?.settlement.neededAModel == true,
        "the settlement records that a model was asked"
    )
    report.expect(
        adjudicated.first?.candidates.count == 2,
        "both readings are kept for the reader to see"
    )

    // An adjudicator that fails must not lose the block, and must not be
    // allowed to hand the page to the model that can invent text.
    let failed = await Reconciler(
        language: chinese,
        adjudicator: ScriptedAgent.failing
    ).reconcile(
        readings: [
            reading(.visionOCR, ["合同期限为三年。"]),
            reading(.visionLanguageModel, ["合同期限为五年。"])
        ],
        pageIndex: 0
    )
    report.equal(
        failed.first?.text,
        "合同期限为三年。",
        "a failed adjudication keeps the recognizer's reading"
    )

    // With no adjudicator at all, the same rule holds.
    let unsettled = await Reconciler(language: chinese, adjudicator: nil)
        .reconcile(
            readings: [
                reading(.visionOCR, ["合同期限为三年。"]),
                reading(.visionLanguageModel, ["合同期限为五年。"])
            ],
            pageIndex: 0
        )
    report.equal(
        unsettled.first?.text,
        "合同期限为三年。",
        "with no model, the recognizer's reading stands"
    )

    // The PDF's own text settles without a model, whatever OCR saw.
    let authoritative = await Reconciler(
        language: chinese,
        adjudicator: ScriptedAgent { _, _ in
            throw AgentFailure.refused("the text layer must not need a model")
        }
    ).reconcile(
        readings: [
            reading(.pdfTextLayer, ["合同期限为三年。"]),
            reading(.visionOCR, ["合同期限为二年。"])
        ],
        pageIndex: 0
    )
    report.equal(
        authoritative.first?.settlement,
        .textLayer,
        "the PDF's own text settles the block"
    )
    report.equal(
        authoritative.first?.text,
        "合同期限为三年。",
        "the text layer wins over the recognizer"
    )

    // Text only the language model reported is kept, and marked.
    let invented = await Reconciler(
        language: chinese,
        adjudicator: ScriptedAgent.always("A")
    ).reconcile(
        readings: [
            reading(.visionOCR, ["合同期限为三年。"]),
            reading(
                .visionLanguageModel,
                ["合同期限为三年。", "完全不同的另一段文字在此处。"]
            )
        ],
        pageIndex: 0
    )
    let onlyModel = invented.first {
        $0.settlement == .single(.visionLanguageModel)
    }
    report.expect(
        onlyModel != nil,
        "a block only the model saw is marked as such"
    )

    // A single reader is not a double-check, and the block says so rather
    // than claiming perfect agreement.
    let alone = await Reconciler(language: chinese, adjudicator: nil)
        .reconcile(readings: [reading(.visionOCR, agreed)], pageIndex: 0)
    report.expect(
        alone.first?.agreement == nil,
        "one reader means agreement is unknown, not 1"
    )
    report.expect(
        alone.first?.wasDoubleChecked == false,
        "one reader is not a double-check"
    )
}
