import DocCore
import Foundation

/// The agent that asks before it guesses.
///
/// Everything else in this pipeline is a check on work already done. This one
/// runs before the translation exists, and it exists because some translation
/// errors cannot be caught afterwards at all. If a document says 对方 and the
/// translator does not know whether that is the other party to a contract or
/// the other side in a dispute, it will pick one, write a fluent sentence
/// around it, and every downstream check will pass: the reading was right,
/// the figures match, the reviewer approves, and the English is wrong in a
/// way nothing in the output reveals.
///
/// The reader knows what the document is. They are the only participant here
/// who does. Asking them three questions costs one dialog; not asking costs a
/// plausible translation of a document that says something else.
public struct ClarificationAgent: Sendable {
    /// Below this there is not enough document to have a question about.
    static let minimumSample = 40

    private let languages: LanguagePair
    private let agent: any TextAgent
    private let limit: Int

    public init(
        languages: LanguagePair,
        agent: any TextAgent,
        limit: Int = 3
    ) {
        self.languages = languages
        self.agent = agent
        self.limit = limit
    }

    /// - Parameter sample: the `DocumentSurvey`'s reading of the document —
    ///   the same text the profile was built from. The questions worth asking
    ///   are rarely all raised by the first page: a term of art that only
    ///   turns up in the middle of a contract is exactly the kind of thing
    ///   the reader can settle and the app cannot.
    public func questions(
        from sample: String
    ) async -> [ClarificationQuestion] {
        guard sample.count >= Self.minimumSample else { return [] }
        do {
            let answer = try await agent.answer(
                instructions: AgentPrompts.clarificationInstructions(
                    languages: languages
                ),
                prompt: AgentPrompts.clarificationPrompt(sample: sample),
                expecting: .prose(approximately: 900)
            )
            return AgentPrompts.questions(from: answer, limit: limit)
        } catch {
            // Not being able to ask is not a reason to stop. The translation
            // proceeds on the document alone, which is what it would have
            // done before this stage existed.
            return []
        }
    }
}
