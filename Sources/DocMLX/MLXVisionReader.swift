#if MLXEngine

import CoreImage
import DocCore
import Foundation
import MLXLMCommon

/// The app's own second reader: a vision-language model running in this
/// process, on this machine's GPU.
///
/// This is what the double-check is for. Apple Vision recognizes glyph shapes
/// and knows nothing about what the sentence says; this model reads the page
/// the way a person skimming it does. Their mistakes do not overlap, which is
/// the only reason comparing them means anything.
///
/// Running it in-process rather than through a server is not only
/// convenience. There is no socket, no port, no other program holding the
/// page, and nothing to misconfigure: the image goes from a `CGImage` in this
/// address space into a tensor in this address space.
public struct MLXVisionReader: PageTranscriber {
    public let reader: PageReader = .visionLanguageModel
    private let store: MLXModelStore
    /// The long side the page is scaled to before the model sees it.
    ///
    /// Larger than the app hands a remote model, because there is no encoding
    /// or transport cost here, and dense Chinese type is exactly what a
    /// too-small image destroys: at 768 pixels a page of 宋体 turns into rows
    /// of grey smudges that the model will confidently read as plausible
    /// sentences.
    private let longSide: Int

    public init(store: MLXModelStore, longSide: Int = 1_400) {
        self.store = store
        self.longSide = longSide
    }

    public var engineName: String {
        "a local vision model"
    }

    public func transcribe(
        _ page: PageImage,
        language: SourceLanguage
    ) async throws -> PageReading {
        let started = Date()
        let container = try await store.prepare()
        let scaled = ImageScaling.scaled(page.image, longSide: longSide)
            ?? page.image

        // A fresh session per page, deliberately. `ChatSession` keeps the
        // conversation's key-value cache, and a run that reuses one puts page
        // one's contents into page two's context — slower every page, and a
        // model that starts completing the previous page instead of reading
        // this one.
        let session = ChatSession(
            container,
            instructions: AgentPrompts.transcriptionInstructions(
                for: language
            ),
            generateParameters: GenerateParameters(
                // Enough for a dense page. A transcription that stops
                // half-way looks exactly like a page that ends half-way.
                maxTokens: 4_096,
                // Transcription is the one job here with a single right
                // answer, so the sampling is greedy.
                temperature: 0
            ),
            // No resizing by the library: the page has already been scaled to
            // a size chosen for reading, and a second resize to 512 square
            // would undo it.
            processing: UserInput.Processing(resize: nil)
        )

        let answer = try await session.respond(
            to: AgentPrompts.transcriptionRequest(for: language),
            image: .ciImage(CIImage(cgImage: scaled))
        )

        return PageReading(
            reader: reader,
            pageIndex: page.index,
            blocks: AgentPrompts.blocks(
                fromTranscription: answer,
                pageIndex: page.index,
                language: language
            ),
            seconds: Date().timeIntervalSince(started)
        )
    }
}

#endif
