#if MLXEngine
import CoreGraphics
import DocAgents
import DocCore
import DocIngest
import DocMLX
import DocOCR
import DocRender
import Foundation
import ImageIO
import LanguageChinese
import UniformTypeIdentifiers

/// The whole app, on a real page, with real engines.
///
/// Everything else that touches a model checks one piece. This runs what a
/// reader runs: two readers on the same page, a model settling what they
/// disagree about, a model translating and a second pass reviewing, the
/// mechanical checks over the result, and the translated page written back
/// out. It is slow and it needs the weights, so it is a command rather than
/// a check — but it is the only thing that answers "does the product work".
enum FullRun {
    static func run(writingTo directory: URL) async throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        guard let image = Fixtures.page(
            lines: Fixtures.dense,
            footer: "第 1 页",
            fontSize: 30,
            startY: 150
        ) else { return }

        let source = directory.appendingPathComponent("run-original.png")
        guard let destination = CGImageDestinationCreateWithURL(
            source as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)

        let provider = try DocumentLoader.open(source)
        let store = MLXModelStore()
        let model = await store.model
        print("Loading \(model.displayName)…")
        _ = try await store.prepare()

        let agent = MLXTextAgent(store: store, name: model.displayName)
        let engines = Engines(
            readers: [VisionTranscriber(), MLXVisionReader(store: store)],
            textAgent: agent,
            machineTranslator: nil,
            preference: .followsInstructions
        )

        let started = Date()
        let document = try await TranslationPipeline(
            languages: SimplifiedChinese.toEnglish,
            engines: engines
        ).run(
            provider,
            brief: TranslationBrief(
                instructions: ["Keep personal names in Chinese."],
                glossary: [
                    GlossaryTerm(term: "王小明", handling: .keepAsWritten)
                ]
            ),
            clarify: nil,
            onEvent: { event in
                switch event {
                case .readerFinished(let reader, _, let blocks, let seconds):
                    print(
                        "  \(reader.displayName): \(blocks) blocks in "
                            + String(format: "%.1f", seconds) + "s"
                    )
                case .pageReconciled(_, let blocks, let contested):
                    print("  reconciled: \(blocks) blocks, \(contested) contested")
                case .blockTranslated(_, _, let index, let of):
                    print("  translated \(index + 1)/\(of)")
                default:
                    break
                }
            }
        )
        print(
            "Finished in "
                + String(format: "%.0f", Date().timeIntervalSince(started))
                + "s\n"
        )

        for block in document.blocks {
            let band = block.confidence.band
            let mark = band == .high ? "  " : (band == .check ? "? " : "! ")
            print("\(mark)\(block.text)")
            if band != .high {
                for reason in block.confidence.reasons {
                    print("     · \(reason)")
                }
            }
        }

        let pdf = try LayoutPreservingPDF.render(document, pages: provider)
        try pdf.write(
            to: directory.appendingPathComponent("run-translated.pdf"),
            options: .atomic
        )
        try PlainTextExport.render(document).write(
            to: directory.appendingPathComponent("run-text.txt"),
            atomically: true,
            encoding: .utf8
        )
        try HTMLExport.render(document, style: .audit).write(
            to: directory.appendingPathComponent("run-audit.html"),
            atomically: true,
            encoding: .utf8
        )
        print("\nWrote the three outputs to \(directory.path)")
    }
}
#endif
