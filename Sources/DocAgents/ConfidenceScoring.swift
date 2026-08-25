import DocCore
import Foundation

/// How much of the app's own work it is willing to vouch for.
///
/// Every number in here is a judgement, and they are all in one place so they
/// can be argued with. Two rules shape them:
///
/// **A blocking mechanical finding outranks everything.** A dropped figure is
/// not offset by two readers agreeing and a reviewer approving — those three
/// are exactly the conditions under which a dropped figure goes unnoticed, so
/// they must not be allowed to vote it down.
///
/// **An unchecked block is not a confident one.** Where only one reader saw a
/// block, or no reviewer looked at the translation, the score says so.
/// Reporting high confidence for work nobody checked is the specific failure
/// this app exists to avoid.
public enum ConfidenceScoring {
    /// What a block starts with before anything is held against it: two
    /// readers agreeing exactly, a translation, and a reviewer who approved
    /// it.
    static let ceiling = 1.0
    /// The most a block can score when a mechanical check found something
    /// blocking — below the "worth a look" band, so it cannot be buried.
    static let blockingCeiling = 0.35

    public struct Inputs: Sendable {
        public let agreement: Double?
        public let settlement: Settlement
        public let findings: [IntegrityFinding]
        /// How alike the two translators' answers were, when two translated
        /// it. Nil when only one did.
        public let translatorAgreement: Double?
        /// Whether a reviewer looked at it, and what it said.
        public let reviewed: Bool
        public let revised: Bool

        public init(
            agreement: Double?,
            settlement: Settlement,
            findings: [IntegrityFinding],
            translatorAgreement: Double?,
            reviewed: Bool,
            revised: Bool
        ) {
            self.agreement = agreement
            self.settlement = settlement
            self.findings = findings
            self.translatorAgreement = translatorAgreement
            self.reviewed = reviewed
            self.revised = revised
        }
    }

    public static func score(_ inputs: Inputs) -> Confidence {
        var score = ceiling
        var reasons: [String] = []

        switch inputs.settlement {
        case .textLayer:
            reasons.append("The PDF's own text, not a recognition")
        case .unanimous:
            reasons.append("Both readers read it the same way")
        case .single(let reader) where reader == .visionLanguageModel:
            // The one case the app treats as closest to unusable: text that
            // only a language model reported.
            score -= 0.45
            reasons.append(
                "Only the vision model reported this — it may not be printed "
                    + "on the page"
            )
        case .single(let reader):
            // Enough to drop a block out of the top band on its own. "One
            // reader saw this" and "two readers agreed" must not land in the
            // same place, or the score stops meaning anything.
            score -= 0.2
            reasons.append("Only \(reader.displayName) read this")
        case .adjudicated(let reader, let because):
            score -= 0.12
            reasons.append(
                "The readers disagreed — \(because) — and \(reader.displayName) "
                    + "was chosen"
            )
        case .defaulted(_, let because):
            score -= 0.3
            reasons.append("The disagreement was not settled: \(because)")
        }

        if let agreement = inputs.agreement, agreement < 1 {
            score -= (1 - agreement) * 0.4
        }

        if let translatorAgreement = inputs.translatorAgreement {
            if translatorAgreement < 0.45 {
                score -= 0.2
                reasons.append(
                    "The two translators produced quite different English"
                )
            }
        } else {
            score -= 0.05
            reasons.append("Only one translator worked on this")
        }

        if !inputs.reviewed {
            score -= 0.2
            reasons.append("No reviewer checked this translation")
        } else if inputs.revised {
            score -= 0.1
            reasons.append("The reviewer rewrote it")
        }

        for finding in inputs.findings {
            switch finding.severity {
            case .blocking: score -= 0.4
            case .caution: score -= 0.12
            case .note: score -= 0.04
            }
            reasons.append(finding.message)
        }

        if inputs.findings.contains(where: { $0.severity == .blocking }) {
            score = min(score, blockingCeiling)
        }

        return Confidence(score: score, reasons: reasons)
    }
}
