import DocAgents
import DocCore
import Foundation

/// What the app is willing to vouch for.
func runConfidenceChecks(_ report: Report) {
    report.begin("confidence")

    func score(
        agreement: Double? = 1,
        settlement: Settlement = .unanimous,
        findings: [IntegrityFinding] = [],
        translatorAgreement: Double? = 0.9,
        reviewed: Bool = true,
        revised: Bool = false
    ) -> Confidence {
        ConfidenceScoring.score(
            ConfidenceScoring.Inputs(
                agreement: agreement,
                settlement: settlement,
                findings: findings,
                translatorAgreement: translatorAgreement,
                reviewed: reviewed,
                revised: revised
            )
        )
    }

    report.equal(
        score().band,
        .high,
        "agreed, translated twice and reviewed is high confidence"
    )

    // The rule the whole scoring exists for: a blocking mechanical finding
    // cannot be outvoted by everything else going right, because everything
    // else going right is exactly when a dropped figure goes unnoticed.
    let dropped = IntegrityFinding(
        kind: .droppedNumber,
        severity: .blocking,
        message: "5000 is missing"
    )
    report.expect(
        score(findings: [dropped]).band == .low,
        "a blocking finding cannot score above 'needs a human'"
    )
    report.expect(
        score(findings: [dropped]).score <= 0.35,
        "and is capped no matter what else agreed"
    )

    // Nobody checked is not the same as everybody agreed.
    report.expect(
        score(agreement: nil, settlement: .single(.visionOCR)).band != .high,
        "a block only one reader saw is not high confidence"
    )
    report.expect(
        score(reviewed: false).band != .high,
        "an unreviewed translation is not high confidence"
    )
    report.expect(
        score(
            agreement: 0,
            settlement: .single(.visionLanguageModel)
        ).band == .low,
        "text only the language model reported is the least trusted"
    )

    // A settled disagreement costs something, but not everything.
    let settled = score(
        agreement: 0.9,
        settlement: .adjudicated(chose: .visionOCR, because: "“未” against “末”")
    )
    report.expect(
        settled.band == .check,
        "an adjudicated block is worth a look, not a rejection"
    )
    report.expect(
        settled.reasons.contains { $0.contains("未") },
        "and the reason names what they differed about"
    )

    report.expect(
        score(translatorAgreement: 0.2).band != .high,
        "two translators saying different things lowers confidence"
    )

    report.begin("confidence/bands")
    report.equal(Confidence(score: 0.95).band, .high, "0.95 is high")
    report.equal(Confidence(score: 0.7).band, .check, "0.7 is worth a look")
    report.equal(Confidence(score: 0.2).band, .low, "0.2 needs a human")
    report.equal(
        Confidence(score: 5).score,
        1,
        "a score cannot exceed 1"
    )
}
