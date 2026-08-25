#if MLXEngine

import CoreImage
import DocCore
import CoreGraphics
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
    /// The box the page is fitted into before the model sees it.
    ///
    /// 1024 is measured, not chosen. On a rendered page of twelve lines of
    /// 30 px Chinese — a court notice with case numbers, an ID number, and
    /// five money figures — the same model, same weights, same greedy
    /// decode, produced:
    ///
    /// | fitted into | similarity to the page | figures kept |
    /// | --- | --- | --- |
    /// | 512 | 0.09 | 6 of 14 |
    /// | 768 | 0.03 | 0 of 14 |
    /// | 1024 | 0.70 | 7 of 14 |
    /// | 1280 | 0.70 | 7 of 14 |
    ///
    /// The two small sizes do not degrade, they *fail*: at 512 the model
    /// invented a different document — a civil judgment, with a case number
    /// and a legal representative that are not on the page — and at 768 it
    /// repeated the title eight times. Neither looks like a failure in the
    /// output. Both look like a transcription.
    ///
    /// 1280 buys nothing over 1024 and costs 40% more time, so 1024 it is.
    ///
    /// A `nil` resize is not an option, whatever it looks like: the image is
    /// then dropped entirely and the model answers about "the text you
    /// provided", having seen none.
    private let fitInto: CGSize

    public init(
        store: MLXModelStore,
        fitInto: CGSize = CGSize(width: 1_024, height: 1_024)
    ) {
        self.store = store
        self.fitInto = fitInto
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
            // The library fits the page inside this box, preserving its
            // aspect ratio. See `fitInto` for why the number is what it is
            // and why it is never nil.
            processing: UserInput.Processing(resize: fitInto)
        )

        let answer = try await session.respond(
            to: AgentPrompts.transcriptionRequest(for: language),
            image: .ciImage(CIImage(cgImage: page.image))
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
