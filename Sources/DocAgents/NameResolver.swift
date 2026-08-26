import DocCore
import Foundation

/// Looks the names up before anything is translated.
///
/// The other stages of this pipeline all improve a translation. This one
/// prevents a particular kind of nonsense that no amount of improvement
/// reaches.
///
/// 布洛芬 is ibuprofen. Not because the characters say so — they say "bù luò
/// fēn", which is how Chinese borrowed the English word in the first place —
/// but because that is what the drug is called. A model translating one line
/// of a prescription at a time has two ways to answer: recall the name, or
/// spell the characters out. The second produces "Buluofen", and everything
/// downstream approves of it. The reviewer sees a source it agrees with. The
/// figures match. The length is right. The English reads as English. The only
/// participant who could catch it is the reader, and the reader came to this
/// app because they cannot read the source.
///
/// So the names are settled once, from the same survey the profile was built
/// from, by a model that has been told what the document is and asked to
/// recall rather than to render. What comes back is carried to every block
/// that contains one of them, checked mechanically in the output, and shown
/// to the reader — who is then in a position to say "that is not my
/// medicine", which is the whole point.
///
/// Nothing here is a dictionary. The app ships no drug list, no company
/// register, no table of statutes; it could not carry one that stayed current
/// and it would still miss the document in front of it. What it does instead
/// is ask the question separately, in a call whose only job is that question,
/// with an instruction to say `UNKNOWN` rather than guess — because a
/// transliteration the reader can see is a problem they can solve, and an
/// invented name is one they cannot.
public struct NameResolver: Sendable {
    /// Below this there is not enough document to have names in it worth
    /// looking up.
    static let minimumSample = 60
    /// How many names one document may settle. Twenty is a prescription with
    /// a long list on it or a contract's worth of parties and statutes; past
    /// that the list stops being names and starts being vocabulary, which is
    /// what the profile's terms are for.
    static let limit = 20

    private let languages: LanguagePair
    private let agent: any TextAgent

    public init(languages: LanguagePair, agent: any TextAgent) {
        self.languages = languages
        self.agent = agent
    }

    /// - Parameters:
    ///   - sample: the `DocumentSurvey`'s reading of the document — the same
    ///     text the profile and the questions came from.
    ///   - profile: what the document turned out to be. Handed over because
    ///     it is what makes the answer specific: the same three characters
    ///     are a drug on a prescription, a company on an invoice, and a place
    ///     on a shipping note, and a model that knows which is looking for
    ///     one kind of name rather than any.
    ///   - brief: what the reader said, which outranks what the app decided.
    public func names(
        from sample: String,
        profile: DocumentProfile,
        brief: TranslationBrief = .none
    ) async -> [ResolvedName] {
        guard sample.count >= Self.minimumSample else { return [] }
        do {
            let answer = try await agent.answer(
                instructions: AgentPrompts.nameInstructions(
                    languages: languages,
                    profile: profile,
                    brief: brief,
                    limit: Self.limit
                ),
                prompt: AgentPrompts.namePrompt(sample: sample),
                expecting: .prose(approximately: 900)
            )
            return AgentPrompts.names(
                from: answer,
                language: languages.source,
                limit: Self.limit
            )
        } catch {
            // Not being able to look the names up is not a reason to refuse
            // to translate. The blocks are translated as they were before
            // this stage existed — and the mechanical check still fires on a
            // name that comes back spelled out, which is the half of this
            // that does not need a model to work.
            return []
        }
    }
}
