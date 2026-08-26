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

        // Neither is a block with no Simplified Chinese in it. A form is
        // mostly figures — 68.4, 0-450, mg/L, CFU/mL — and handing them to a
        // translator is not merely a wasted call per cell: they come back
        // changed. "4" comes back "Four", "mg/L" comes back "Mg/l", and
        // because the layout-preserving export replaces any block whose
        // English differs from its source, a correct figure printed on the
        // original page is painted over with a worse one. The whole point of
        // a results table is its figures.
        guard languages.source.scriptShare(of: block.text) > 0 else {
            return TranslatedBlock(
                source: block,
                firstDraft: block.text,
                confidence: Confidence(
                    score: 1,
                    reasons: [
                        "No \(languages.source.englishName) in it, kept as "
                            + "printed"
                    ]
                )
            )
        }

        // How much of the page around this block it turns out to need. A
        // sentence that stands on its own is translated on its own; one that
        // points at something outside itself is shown what it points at. See
        // `ContextNeed` for why this is decided per block rather than settled
        // once for the document.
        let need = AdaptiveContext.need(
            for: block.text,
            kind: block.kind,
            available: context,
            language: languages.source
        )

        var attempt: Attempt
        do {
            attempt = try await translate(
                block,
                following: context,
                need: need
            )
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
                ),
                context: need
            )
        }

        // A block handed back as its own source, having been shown the page
        // around it, gets one more try with nothing around it. See
        // `ContextNeed.retriedAlone` for the measurement behind this: context
        // in front of a block that is nearly all figures is enough to tip a
        // small model from translating into copying, and the mechanical check
        // has already noticed. The second call is paid only where the first
        // one demonstrably failed, and it is kept only if it did better.
        var spent = need
        if attempt.copiedTheSource, !need.isEmpty,
           let alone = try? await translate(
               block,
               following: .none,
               need: .none
           ), !alone.copiedTheSource {
            attempt = alone
            spent = .alone
        }

        return TranslatedBlock(
            source: block,
            firstDraft: attempt.draft,
            revision: attempt.verdict?.revision,
            findings: attempt.findings,
            confidence: ConfidenceScoring.score(
                ConfidenceScoring.Inputs(
                    agreement: block.agreement,
                    settlement: block.settlement,
                    findings: attempt.findings,
                    translatorAgreement: attempt.translatorAgreement,
                    reviewed: attempt.verdict != nil,
                    revised: attempt.verdict?.revision != nil
                )
            ),
            context: spent
        )
    }

    /// One go at a block: translate it, take a second opinion, review it, and
    /// run the mechanical checks over what comes out.
    ///
    /// Separated out because it is done twice for a block that comes back
    /// untranslated, and a second attempt that skipped the review would be a
    /// different question rather than the same one asked again.
    private struct Attempt {
        var draft: String
        var verdict: AgentPrompts.ReviewVerdict?
        var findings: [IntegrityFinding]
        var translatorAgreement: Double?

        /// Whether the translator handed the source back rather than
        /// translating it. Both findings mean that: one for an answer
        /// identical to the source, one for an answer still largely in the
        /// source script.
        var copiedTheSource: Bool {
            findings.contains {
                $0.kind == .echoedSource || $0.kind == .untranslatedScript
            }
        }
    }

    private func translate(
        _ block: ReconciledBlock,
        following context: TranslationContext,
        need: ContextNeed
    ) async throws -> Attempt {
        let draft = try await translated(
            block,
            following: context,
            need: need
        )
        let secondDraft = await secondDraft(of: block)
        let verdict = await review(block: block, draft: draft)
        let final = verdict?.revision ?? draft
        return Attempt(
            draft: draft,
            verdict: verdict,
            findings: TextIntegrity.check(
                source: block.text,
                translation: final,
                language: languages.source,
                target: languages.target,
                brief: brief,
                profile: profile
            ),
            translatorAgreement: secondDraft.map {
                TextSimilarity.score(draft, $0)
            }
        )
    }

    private func translated(
        _ block: ReconciledBlock,
        following context: TranslationContext,
        need: ContextNeed
    ) async throws -> String {
        if let agentTranslator = translator as? TextAgentTranslator {
            return try await agentTranslator.translate(
                block.text,
                kind: block.kind,
                languages: languages,
                following: context,
                need: need
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
                    agreedTerms: profile.termLines(appearingIn: block.text),
                    agreedNames: profile.nameLines(appearingIn: block.text)
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
