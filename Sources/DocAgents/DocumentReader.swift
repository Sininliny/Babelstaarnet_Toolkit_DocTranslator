import DocCore
import Foundation

/// Reads the document before any of it is translated.
///
/// One pass, one model call, and every sentence afterwards is translated as
/// part of something rather than on its own. What it produces is not a
/// summary for the reader — it is working notes for the translator: what kind
/// of document this is, how it should sound, and the handful of recurring
/// terms that have more than one defensible rendering.
///
/// That last part is the one that pays. A sentence-at-a-time translator will
/// render 甲方 as "Party A" on one line and "the first party" on another, and
/// both are correct in isolation, so nothing downstream flags it and the
/// document reads as though two people produced it. Deciding once and handing
/// the decision to every call is the only thing that fixes it.
///
/// What it reads is a `DocumentSurvey` — text taken from across the document
/// rather than off the front of it. Profiling from the opening alone would
/// answer the question this stage exists to ask with whatever happened to be
/// on the cover page.
public struct DocumentReader: Sendable {
    /// Below this there is not enough document to have a view about. A
    /// profile guessed from one line is a guess applied to every line, and a
    /// wrong profile is worse than none: it is confidently wrong in every
    /// block instead of absent from all of them.
    public static let minimumSample = 60

    private let languages: LanguagePair
    private let agent: any TextAgent

    public init(languages: LanguagePair, agent: any TextAgent) {
        self.languages = languages
        self.agent = agent
    }

    public func profile(from sample: String) async -> DocumentProfile {
        guard sample.count >= Self.minimumSample else { return .unknown }
        do {
            let answer = try await agent.answer(
                instructions: AgentPrompts.documentProfileInstructions(
                    languages: languages
                ),
                prompt: AgentPrompts.documentProfilePrompt(sample: sample),
                expecting: .prose(approximately: 700)
            )
            return AgentPrompts.profile(from: answer)
        } catch {
            // Not being able to read the document first is not a reason to
            // refuse to translate it. The blocks are translated as they were
            // before this stage existed, and the confidence score already
            // says that only one translator worked on them.
            return .unknown
        }
    }
}
