import CoreGraphics
import DocCore
import Foundation

/// A model that answers from a script.
///
/// Every agent in this app is behind a protocol so that the whole pipeline
/// can be run without one. That is not only for speed: the interesting
/// behaviour is what the app does when a model says something unhelpful, and
/// there is no way to make a real model reliably say something unhelpful.
struct ScriptedAgent: TextAgent {
    let engineName = "scripted"
    let isBuiltIn = false
    /// Called with the prompt; returns the answer, or throws.
    let answering: @Sendable (String, AnswerShape) throws -> String

    func status(for role: EngineRole) async -> EngineStatus {
        EngineStatus(
            engineName: engineName,
            role: role,
            state: .ready,
            isBuiltIn: false
        )
    }

    func answer(
        instructions: String,
        prompt: String,
        expecting: AnswerShape
    ) async throws -> String {
        try answering(prompt, expecting)
    }

    static func always(_ answer: String) -> ScriptedAgent {
        ScriptedAgent { _, _ in answer }
    }

    static let failing = ScriptedAgent { _, _ in
        throw AgentFailure.notAvailable("no model in this check")
    }
}

/// A translator that applies a fixed mapping, so a check can assert on the
/// English without a model in the loop.
struct ScriptedTranslator: TranslationEngine {
    let engineName: String
    let isBuiltIn = false
    let translating: @Sendable (String) -> String

    init(
        engineName: String = "scripted translator",
        translating: @escaping @Sendable (String) -> String
    ) {
        self.engineName = engineName
        self.translating = translating
    }

    func status(for languages: LanguagePair) async -> EngineStatus {
        EngineStatus(
            engineName: engineName,
            role: .translator,
            state: .ready,
            isBuiltIn: false
        )
    }

    func translate(
        _ text: String,
        languages: LanguagePair
    ) async throws -> String {
        translating(text)
    }
}

/// A reader that returns blocks it was handed.
struct ScriptedReader: PageTranscriber {
    let reader: PageReader
    let pages: [Int: [SourceBlock]]

    func transcribe(
        _ page: PageImage,
        language: SourceLanguage
    ) async throws -> PageReading {
        PageReading(
            reader: reader,
            pageIndex: page.index,
            blocks: pages[page.index] ?? [],
            seconds: 0
        )
    }
}

/// A one-pixel document, because the readers in a check never look at it.
struct BlankPages: PageProvider {
    let source: DocumentSource
    var layers: [Int: PageReading] = [:]

    init(pageCount: Int) {
        source = DocumentSource(
            url: URL(fileURLWithPath: "/tmp/check.pdf"),
            kind: .pdf,
            pageCount: pageCount
        )
    }

    func page(at index: Int) throws -> PageImage {
        let context = CGContext(
            data: nil,
            width: 8,
            height: 8,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        return PageImage(
            index: index,
            image: context.makeImage()!,
            pointSize: CGSize(width: 8, height: 8)
        )
    }

    func textLayer(at index: Int) -> PageReading? { layers[index] }
}

/// A block, briefly.
func block(
    _ text: String,
    order: Int = 0,
    page: Int = 0,
    kind: BlockKind = .paragraph,
    y: Double = 0
) -> SourceBlock {
    SourceBlock(
        pageIndex: page,
        order: order,
        box: BlockBox(x: 0.1, y: y, width: 0.8, height: 0.04),
        kind: kind,
        lines: [text],
        text: text,
        confidence: 0.9
    )
}
