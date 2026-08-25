import CoreGraphics
import CoreImage
import DocCore
import Foundation
import FoundationModels

/// The second reader: the system model, looking at the page itself.
///
/// This is what makes the check a real double-check rather than one engine
/// grading its own homework. Vision recognizes glyph shapes and knows nothing
/// about what the sentence says; a vision-language model reads the page the
/// way a person skimming it does, and its mistakes are of a completely
/// different kind. Vision confuses 未 and 末; a language model does not,
/// because the sentence only works one way. A language model will quietly
/// smooth a smudged clause into something plausible; Vision will not, because
/// it is not writing anything.
///
/// Two readers whose failure modes overlap would agree on the same errors and
/// the agreement score would mean nothing. These two do not overlap, which is
/// the whole reason the score is worth computing.
@available(macOS 27.0, *)
public struct SystemVisionReader: PageTranscriber {
    public let reader: PageReader = .visionLanguageModel
    /// The long side the page is scaled to before it is handed over.
    ///
    /// Not the reading resolution. The recognizer wants every stroke of every
    /// hanzi and gets 300 dpi; the model works from a much smaller internal
    /// representation regardless of what it is given, so a larger image costs
    /// time and memory without being read any more closely.
    private let longSide: Int

    public init(longSide: Int = 1_536) {
        self.longSide = longSide
    }

    public static func isAvailable() -> Bool {
        let model = SystemLanguageModel(
            useCase: .general,
            guardrails: .permissiveContentTransformations
        )
        return model.isAvailable && model.capabilities.contains(.vision)
    }

    public func status() -> EngineStatus {
        let model = SystemLanguageModel(
            useCase: .general,
            guardrails: .permissiveContentTransformations
        )
        let state: EngineStatus.State
        if case .ready = SystemTextAgent.state(of: model) {
            state = model.capabilities.contains(.vision)
                ? .ready
                : .unavailable("The on-device model cannot read images.")
        } else {
            state = SystemTextAgent.state(of: model)
        }
        return EngineStatus(
            engineName: "Apple on-device model (vision)",
            role: .pageReader,
            state: state,
            isBuiltIn: true
        )
    }

    public func transcribe(
        _ page: PageImage,
        language: SourceLanguage
    ) async throws -> PageReading {
        let started = Date()
        let model = SystemLanguageModel(
            useCase: .general,
            guardrails: .permissiveContentTransformations
        )
        guard model.isAvailable, model.capabilities.contains(.vision) else {
            throw AgentFailure.notAvailable(
                "The on-device model cannot read images on this Mac."
            )
        }

        let image = ImageScaling.scaled(page.image, longSide: longSide)
            ?? page.image
        let brief = AgentPrompts.transcriptionInstructions(for: language)
        let session = LanguageModelSession(model: model, instructions: brief)

        let response: String
        do {
            let answer = try await session.respond(
                options: GenerationOptions(
                    // Transcription is the one job in this pipeline with
                    // exactly one right answer, so the sampling is as close
                    // to deterministic as the API allows.
                    temperature: 0,
                    maximumResponseTokens: 4_096
                )
            ) {
                AgentPrompts.transcriptionRequest(for: language)
                Attachment(image).label("page")
            }
            response = answer.content
        } catch let error as LanguageModelSession.GenerationError {
            throw SystemTextAgent.translate(error)
        }

        return PageReading(
            reader: reader,
            pageIndex: page.index,
            blocks: AgentPrompts.blocks(
                fromTranscription: response,
                pageIndex: page.index,
                language: language
            ),
            seconds: Date().timeIntervalSince(started)
        )
    }
}
