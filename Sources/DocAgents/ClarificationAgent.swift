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

    /// - Parameters:
    ///   - sample: the `DocumentSurvey`'s reading of the document — the same
    ///     text the profile was built from. The questions worth asking are
    ///     rarely all raised by the first page: a term of art that only turns
    ///     up in the middle of a contract is exactly the kind of thing the
    ///     reader can settle and the app cannot.
    ///   - profile: what the document turned out to be. Consulted for one
    ///     thing: whether the field is still unknown. If the app could not
    ///     work out what kind of work this document belongs to, that question
    ///     is asked first and ahead of anything the model thought of, because
    ///     no other answer changes as many words. It decides what every name
    ///     in the document is called.
    public func questions(
        from sample: String,
        profile: DocumentProfile = .unknown
    ) async -> [ClarificationQuestion] {
        guard sample.count >= Self.minimumSample else { return [] }
        // Asked by the app rather than by a model, and asked whenever the
        // field is unknown rather than when a model thinks to wonder about
        // it. A model that has just failed to say what field a document
        // belongs to is not the right participant to decide whether that
        // matters.
        let ownQuestions = profile.field.isKnown
            ? []
            : [DocumentField.clarification]
        do {
            let answer = try await agent.answer(
                instructions: AgentPrompts.clarificationInstructions(
                    languages: languages
                ),
                prompt: AgentPrompts.clarificationPrompt(sample: sample),
                expecting: .prose(approximately: 900)
            )
            return Array(
                (ownQuestions
                    + AgentPrompts.questions(from: answer, limit: limit))
                    .prefix(limit)
            )
        } catch {
            // Not being able to ask a model is not a reason to stop, and
            // not a reason to drop the app's own question either: the field
            // still decides every name in the document, and asking about it
            // needs no model.
            return ownQuestions
        }
    }
}
