import DocCore
import Foundation

/// One block, translated and checked.
///
/// The check has three independent parts, and they are independent on
/// purpose:
///
/// - **A second translator**, where one is available. Two engines with no
///   shared machinery producing the same English is evidence; the same engine
///   asked twice is not.
/// - **A reviewing model**, which reads the source and the draft together and
///   is allowed to rewrite. This is the part that catches meaning: a dropped
///   negation, an obligation turned into a permission.
/// - **`TextIntegrity`**, which catches what a reviewing model reliably does
///   not. It is another language model with the same blind spots, and it will
///   approve a fluent paragraph whose figures changed. The mechanical checks
///   will not.
///
/// Any one of the three can be absent — on a Mac with Apple Intelligence
/// turned off, two of them are — and the confidence score says so rather than
/// quietly meaning something different.
///
/// All three see the `DocumentProfile`, and the reason is that none of them
/// can see the document. They are each shown one block, which is the only way
/// a translation of any length is affordable, and it is also the reason a
/// pipeline built this way drifts: the block is right, the next block is
/// right, and the two disagree about what 甲方 is called. The profile is what
/// the whole document knows, carried down to a stage that can only see one
/// paragraph of it.
public struct BlockTranslator: Sendable {
    private let languages: LanguagePair
    private let translator: any TranslationEngine
    private let secondOpinion: (any TranslationEngine)?
    private let reviewer: (any TextAgent)?
    private let brief: TranslationBrief
    private let profile: DocumentProfile

    public init(
        languages: LanguagePair,
        translator: any TranslationEngine,
        secondOpinion: (any TranslationEngine)? = nil,
        reviewer: (any TextAgent)? = nil,
        brief: TranslationBrief = .none,
        profile: DocumentProfile = .unknown
    ) {
        self.profile = profile
        self.languages = languages
        self.translator = translator
        self.secondOpinion = secondOpinion
        self.reviewer = reviewer
        self.brief = brief
    }

    public func translate(
        _ block: ReconciledBlock,
        following context: TranslationContext = .none
    ) async -> TranslatedBlock {
        // Page numbers and running heads are kept as they are. Translating
        // them costs a model call per page and produces "Page 3".
        guard block.kind.isTranslatable else {
            return TranslatedBlock(
                source: block,
                firstDraft: block.text,
                confidence: Confidence(
                    score: 1,
                    reasons: ["Page furniture, kept as printed"]
                )
            )
        }

        let draft: String
        do {
            draft = try await translated(block, following: context)
        } catch {
            return TranslatedBlock(
                source: block,
                firstDraft: "",
                findings: [
                    IntegrityFinding(
                        kind: .emptyTranslation,
                        severity: .blocking,
                        message: "This block could not be translated: "
                            + error.localizedDescription
                    )
                ],
                confidence: Confidence(
                    score: 0,
                    reasons: [error.localizedDescription]
                )
            )
        }

        let secondDraft = await secondDraft(of: block)
        let translatorAgreement = secondDraft.map {
            TextSimilarity.score(draft, $0)
        }

        let verdict = await review(block: block, draft: draft)
        let final = verdict?.revision ?? draft

        let findings = TextIntegrity.check(
            source: block.text,
            translation: final,
            language: languages.source,
            target: languages.target,
            brief: brief,
            profile: profile
        )

        return TranslatedBlock(
            source: block,
            firstDraft: draft,
            revision: verdict?.revision,
            findings: findings,
            confidence: ConfidenceScoring.score(
                ConfidenceScoring.Inputs(
                    agreement: block.agreement,
                    settlement: block.settlement,
                    findings: findings,
                    translatorAgreement: translatorAgreement,
                    reviewed: verdict != nil,
                    revised: verdict?.revision != nil
                )
            )
        )
    }

    private func translated(
        _ block: ReconciledBlock,
        following context: TranslationContext
    ) async throws -> String {
        if let agentTranslator = translator as? TextAgentTranslator {
            return try await agentTranslator.translate(
                block.text,
                kind: block.kind,
                languages: languages,
                following: context
            )
        }
        // A dedicated translation model takes no context and no
        // instructions. That is the trade the pipeline makes when it leads:
        // faster and steadier, and deaf to everything the document says
        // about itself.
        return try await translator.translate(block.text, languages: languages)
    }

    private func secondDraft(of block: ReconciledBlock) async -> String? {
        guard let secondOpinion else { return nil }
        return try? await secondOpinion.translate(
            block.text,
            languages: languages
        )
    }

    private func review(
        block: ReconciledBlock,
        draft: String
    ) async -> AgentPrompts.ReviewVerdict? {
        guard let reviewer, !draft.isEmpty else { return nil }
        do {
            let answer = try await reviewer.answer(
                instructions: AgentPrompts.reviewInstructions(
                    languages: languages,
                    brief: brief,
                    profile: profile,
                    agreedTerms: profile.termLines(appearingIn: block.text)
                ),
                prompt: AgentPrompts.reviewPrompt(
                    source: block.text,
                    draft: draft,
                    languages: languages
                ),
                expecting: .prose(approximately: draft.count + 200)
            )
            return AgentPrompts.verdict(from: answer)
        } catch {
            // A reviewer that failed is a reviewer that did not review. The
            // draft stands and the confidence score records that nobody
            // checked it — which is true, and is the point.
            return nil
        }
    }
}
