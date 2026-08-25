import DocCore
import DocRender
import Foundation
import LanguageChinese

/// What leaves the app when the reader saves the result.
func runExportChecks(_ report: Report) {
    report.begin("export")

    let source = DocumentSource(
        url: URL(fileURLWithPath: "/tmp/合同.pdf"),
        kind: .pdf,
        pageCount: 1
    )
    let reconciled = ReconciledBlock(
        pageIndex: 0,
        order: 0,
        box: .full,
        kind: .paragraph,
        text: "罚款为5000元 <见附件>。",
        candidates: [.visionOCR: "罚款为5000元。"],
        agreement: 0.8,
        settlement: .adjudicated(chose: .visionOCR, because: "“5000” against “500”")
    )
    let translated = TranslatedBlock(
        source: reconciled,
        firstDraft: "The fine is 500 yuan.",
        revision: "The fine is 5000 yuan <see annex>.",
        findings: [
            IntegrityFinding(
                kind: .droppedNumber,
                severity: .blocking,
                message: "5000 is in the source and not in the translation."
            )
        ],
        confidence: Confidence(score: 0.3, reasons: ["A figure changed"])
    )
    let document = TranslatedDocument(
        source: source,
        languages: SimplifiedChinese.toEnglish,
        pages: [TranslatedPage(index: 0, blocks: [translated])],
        engines: EngineRecord(
            readers: ["Vision OCR", "Vision model"],
            adjudicator: "Apple on-device model",
            translator: "Apple Translation",
            reviewer: "Apple on-device model"
        )
    )

    let markdown = MarkdownExport.render(document, style: .audit)
    report.expect(
        markdown.contains("Nothing in this document was uploaded anywhere."),
        "every export says where the work was done"
    )
    report.expect(
        markdown.contains("Vision OCR"),
        "the export records which engines read it"
    )
    report.expect(
        markdown.contains("罚款为5000元"),
        "a side-by-side export carries the source"
    )
    report.expect(
        markdown.contains("⚠︎"),
        "a block that needs a human is marked in the export"
    )
    report.expect(
        markdown.contains("The fine is 500 yuan."),
        "the audit export keeps the first draft"
    )
    report.expect(
        !MarkdownExport.render(document, style: .englishOnly)
            .contains("罚款为5000元"),
        "a translation-only export carries no source"
    )

    let html = HTMLExport.render(document, style: .bilingual)
    report.expect(
        html.contains("&lt;see annex&gt;"),
        "angle brackets in the text are escaped"
    )
    report.expect(
        !html.contains("<see annex>"),
        "and do not reach the page as markup"
    )
    report.expect(
        html.contains("lang=\"zh-Hans\""),
        "the source is tagged with its language"
    )
    // The rule that makes an export safe to open: nothing in it reaches out.
    for reaching in ["http://", "https://", "<script", "src=", "@import"] {
        report.expect(
            !html.contains(reaching),
            "an exported page must not contain \(reaching)"
        )
    }
}
