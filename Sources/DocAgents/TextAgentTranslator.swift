import DocCore
import Foundation

/// A language model in the translator's chair.
///
/// The app has two kinds of translator available and they are not
/// interchangeable. macOS's Translation framework is a dedicated translation
/// model: fast, consistent, and completely unable to take an instruction. A
/// language model is slower and less consistent, and it is the only one of
/// the two that can be told "keep the names in Chinese" or "this is a court
/// filing".
///
/// This wrapper is what lets the pipeline hold both behind one protocol, so
/// which engine translates and which one gives the second opinion is a
/// composition decision rather than a branch in the middle of the pipeline.
public struct TextAgentTranslator: TranslationEngine {
    public var engineName: String { agent.engineName }
    public var isBuiltIn: Bool { agent.isBuiltIn }
    private let agent: any TextAgent
    private let brief: TranslationBrief
    private let documentContext: String?

    public init(
        agent: any TextAgent,
        brief: TranslationBrief = .none,
        documentContext: String? = nil
    ) {
        self.agent = agent
        self.brief = brief
        self.documentContext = documentContext
    }

    public func status(for languages: LanguagePair) async -> EngineStatus {
        await agent.status(for: .translator)
    }

    public func translate(
        _ text: String,
        languages: LanguagePair
    ) async throws -> String {
        try await translate(text, kind: .paragraph, languages: languages)
    }

    /// The kind matters to the prompt: a heading translated as a sentence
    /// comes back with a full stop on it and reads as body text in the
    /// export.
    public func translate(
        _ text: String,
        kind: BlockKind,
        languages: LanguagePair
    ) async throws -> String {
        let answer = try await agent.answer(
            instructions: AgentPrompts.translationInstructions(
                languages: languages,
                brief: brief
            ),
            prompt: AgentPrompts.translationPrompt(
                text: text,
                kind: kind,
                documentContext: documentContext,
                terms: brief.glossary(applyingTo: text)
            ),
            // Room for the expansion the language pack expects, plus the
            // headroom a model needs not to stop mid-sentence.
            expecting: .prose(
                approximately: Int(
                    Double(text.count) * languages.source.expansionRatio.upperBound
                ) + 200
            )
        )
        return AgentPrompts.stripPreamble(
            AgentPrompts.stripFences(answer)
        )
    }
}
