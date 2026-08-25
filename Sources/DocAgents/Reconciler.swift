import DocCore
import Foundation

/// Two readings of a page into one text, with the disagreements recorded.
///
/// The order of authority is fixed here and is not a per-language or
/// per-document setting:
///
/// 1. **The PDF's own text layer**, where it exists. It is not a reading at
///    all — it is the characters that were typeset — so it settles the block
///    without a model being asked, and a born-digital PDF costs no
///    adjudication calls at all.
/// 2. **The character recognizer**, as the working text.
/// 3. **The vision-language model**, as the check on it.
///
/// The one asymmetry worth stating plainly: text that *only* the language
/// model reported is kept, but marked. A recognizer cannot invent a paragraph
/// that is not on the page and a language model can, so a block with no
/// recognizer reading behind it is the app's least trustworthy output, and it
/// says so rather than blending in.
public struct Reconciler: Sendable {
    private let language: SourceLanguage
    private let adjudicator: (any TextAgent)?

    public init(language: SourceLanguage, adjudicator: (any TextAgent)?) {
        self.language = language
        self.adjudicator = adjudicator
    }

    /// Below this the two readings are not two versions of one paragraph, so
    /// asking a model to choose between them is asking the wrong question.
    static let adjudicationFloor = 0.45
    /// Above this they are the same text with a different space in it.
    static let agreementCeiling = 0.999

    public func reconcile(
        readings: [PageReading],
        pageIndex: Int
    ) async -> [ReconciledBlock] {
        let usable = readings.filter { !$0.isEmpty }
        guard let primary = pick(from: usable) else { return [] }
        let secondary = usable.first { $0.reader != primary.reader }

        guard let secondary else {
            return primary.blocks.enumerated().map { order, block in
                ReconciledBlock(
                    pageIndex: pageIndex,
                    order: order,
                    box: block.box,
                    kind: block.kind,
                    lineCount: block.lines.count,
                    text: block.text,
                    candidates: [primary.reader: block.text],
                    agreement: nil,
                    settlement: primary.reader.isAuthoritative
                        ? .textLayer
                        : .single(primary.reader)
                )
            }
        }

        let pairs = BlockAlignment.align(primary.blocks, secondary.blocks)
        var reconciled: [ReconciledBlock] = []
        reconciled.reserveCapacity(pairs.count)

        for pair in pairs {
            guard let block = await settle(
                pair,
                primary: primary.reader,
                secondary: secondary.reader,
                pageIndex: pageIndex,
                order: reconciled.count,
                contextBefore: reconciled.last?.text
            ) else { continue }
            reconciled.append(block)
        }
        return reconciled
    }

    /// The reading that carries the page's geometry and the most authority.
    private func pick(from readings: [PageReading]) -> PageReading? {
        readings.first { $0.reader == .pdfTextLayer }
            ?? readings.first { $0.reader == .visionOCR }
            ?? readings.first
    }

    private func settle(
        _ pair: BlockAlignment.Pair,
        primary: PageReader,
        secondary: PageReader,
        pageIndex: Int,
        order: Int,
        contextBefore: String?
    ) async -> ReconciledBlock? {
        let leftText = language.normalizeReading(pair.leftText)
        let rightText = language.normalizeReading(pair.rightText)

        // Only the language model saw it.
        if pair.left.isEmpty {
            guard !rightText.isEmpty else { return nil }
            return ReconciledBlock(
                pageIndex: pageIndex,
                order: order,
                box: pair.right.first?.box ?? .full,
                kind: pair.right.first?.kind ?? .paragraph,
                lineCount: pair.right.reduce(0) { $0 + $1.lines.count },
                text: rightText,
                candidates: [secondary: rightText],
                agreement: 0,
                settlement: .single(secondary)
            )
        }

        let box = pair.left.dropFirst().reduce(pair.left[0].box) {
            $0.union($1.box)
        }
        let kind = pair.left[0].kind
        let lineCount = pair.left.reduce(0) { $0 + $1.lines.count }

        // Only the recognizer saw it. Ordinary and usually harmless — a
        // model skips page furniture and short table cells constantly — but
        // it is still a block nobody checked.
        if pair.right.isEmpty {
            return ReconciledBlock(
                pageIndex: pageIndex,
                order: order,
                box: box,
                kind: kind,
                lineCount: lineCount,
                text: leftText,
                candidates: [primary: leftText],
                agreement: nil,
                settlement: .single(primary)
            )
        }

        let candidates = [primary: leftText, secondary: rightText]
        let similarity = pair.similarity

        // The text layer is the document's own copy of itself. Whatever the
        // other reader saw, this is what is printed.
        if primary.isAuthoritative {
            return ReconciledBlock(
                pageIndex: pageIndex,
                order: order,
                box: box,
                kind: kind,
                lineCount: lineCount,
                text: leftText,
                candidates: candidates,
                agreement: similarity,
                settlement: .textLayer
            )
        }

        if similarity >= Self.agreementCeiling || leftText == rightText {
            return ReconciledBlock(
                pageIndex: pageIndex,
                order: order,
                box: box,
                kind: kind,
                lineCount: lineCount,
                text: leftText,
                candidates: candidates,
                agreement: 1,
                settlement: .unanimous
            )
        }

        // Page furniture is never translated, so a disagreement about a
        // running head is not worth a model call.
        guard kind.isTranslatable, similarity >= Self.adjudicationFloor,
              let adjudicator else {
            return ReconciledBlock(
                pageIndex: pageIndex,
                order: order,
                box: box,
                kind: kind,
                lineCount: lineCount,
                text: leftText,
                candidates: candidates,
                agreement: similarity,
                settlement: .defaulted(
                    to: primary,
                    because: adjudicator == nil
                        ? "no model was available to choose"
                        : "the two readings are too different to be two "
                            + "readings of the same text"
                )
            )
        }

        // A disagreement that is only about figures is not a question for a
        // language model, and asking one is worse than not asking.
        //
        // Measured on a rendered court notice, the vision model transcribed
        // 京0105执12345号 as 京01执12345号 and dropped digits from an ID
        // number — while producing fluent, entirely plausible Chinese around
        // them. It does not misread digits so much as *rewrite* them. A
        // character recognizer cannot do that: it reads the glyph or it
        // fails. So where the two readings differ in their numbers and
        // nowhere else, the recognizer wins without a vote.
        //
        // The adjudication prompt asks the model for this same preference in
        // words. This makes it a fact instead of a request.
        if Self.differOnlyOnFigures(leftText, rightText) {
            return ReconciledBlock(
                pageIndex: pageIndex,
                order: order,
                box: box,
                kind: kind,
                lineCount: lineCount,
                text: leftText,
                candidates: candidates,
                agreement: similarity,
                settlement: .defaulted(
                    to: primary,
                    because: "they differ only in their figures, and a "
                        + "recognizer cannot invent one"
                )
            )
        }

        let difference = Self.disagreement(between: leftText, and: rightText)
        do {
            let answer = try await adjudicator.answer(
                instructions: AgentPrompts.adjudicationInstructions(
                    for: language
                ),
                prompt: AgentPrompts.adjudicationPrompt(
                    contextBefore: contextBefore,
                    candidateA: leftText,
                    candidateB: rightText
                ),
                expecting: .choice(AgentPrompts.adjudicationChoices)
            )
            let choseB = answer.uppercased().hasPrefix(AgentPrompts.choiceB)
            return ReconciledBlock(
                pageIndex: pageIndex,
                order: order,
                box: box,
                kind: kind,
                lineCount: lineCount,
                text: choseB ? rightText : leftText,
                candidates: candidates,
                agreement: similarity,
                settlement: .adjudicated(
                    chose: choseB ? secondary : primary,
                    because: difference
                )
            )
        } catch {
            // A failed adjudication keeps the recognizer's reading. It is the
            // reader that cannot invent text, so it is the safe default when
            // nobody can settle the question.
            return ReconciledBlock(
                pageIndex: pageIndex,
                order: order,
                box: box,
                kind: kind,
                lineCount: lineCount,
                text: leftText,
                candidates: candidates,
                agreement: similarity,
                settlement: .defaulted(
                    to: primary,
                    because: error.localizedDescription
                )
            )
        }
    }

    /// Whether the two readings say the same thing with different numbers in
    /// it. Compared by removing every digit: what is left is the sentence,
    /// and if the sentences match then the figures are the whole dispute.
    public static func differOnlyOnFigures(_ lhs: String, _ rhs: String) -> Bool {
        let lhsNumbers = TextIntegrity.numberRuns(in: lhs)
        let rhsNumbers = TextIntegrity.numberRuns(in: rhs)
        guard lhsNumbers != rhsNumbers else { return false }
        return withoutDigits(lhs) == withoutDigits(rhs)
    }

    public static func withoutDigits(_ text: String) -> String {
        String(
            text.unicodeScalars.filter { scalar in
                !(scalar.value >= 48 && scalar.value <= 57)
                    && !(scalar.value >= 0xFF10 && scalar.value <= 0xFF19)
            }.map(Character.init)
        )
    }

    /// What the two readers actually differed about, in a form short enough
    /// to put in the interface. "They differed on 未 / 末" is something a
    /// reader can check against the page in a second; "agreement 0.94" is
    /// not.
    static func disagreement(between lhs: String, and rhs: String) -> String {
        guard let leftRun = TextSimilarity.differingRuns(lhs, rhs).first,
              let rightRun = TextSimilarity.differingRuns(rhs, lhs).first
        else {
            return "they differed"
        }
        let left = String(lhs[leftRun]).trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let right = String(rhs[rightRun]).trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !left.isEmpty || !right.isEmpty else { return "they differed" }
        let a = left.isEmpty ? "nothing" : "“\(left.prefix(24))”"
        let b = right.isEmpty ? "nothing" : "“\(right.prefix(24))”"
        return "\(a) against \(b)"
    }
}
