import DocCore
import Foundation

/// Matching one reader's paragraphs to another's.
///
/// The hard part of a double-check is not comparing two strings, it is
/// knowing which two strings to compare. The recognizer returns blocks with
/// positions on the page; a vision-language model returns a list of
/// paragraphs and no geometry at all. There is nothing to match on but the
/// words, and the two readers will not have split the page the same way — one
/// paragraph in the recognizer's reading is routinely two in the model's, and
/// two are routinely one.
///
/// So this is a sequence alignment, not a lookup. Order is preserved, gaps are
/// allowed on both sides, and one block on either side may be matched against
/// two consecutive blocks on the other. Without the merge transitions, a model
/// that joined a heading to the paragraph under it would knock every
/// subsequent block on the page out of step, and a page that agreed
/// completely would score as a page that agreed about nothing.
public enum BlockAlignment {
    public struct Pair: Sendable {
        public let left: [SourceBlock]
        public let right: [SourceBlock]
        public let similarity: Double

        public init(
            left: [SourceBlock],
            right: [SourceBlock],
            similarity: Double
        ) {
            self.left = left
            self.right = right
            self.similarity = similarity
        }

        public var leftText: String { left.map(\.text).joined() }
        public var rightText: String { right.map(\.text).joined() }
    }

    /// Below this, two blocks are different text rather than two readings of
    /// the same text. Set where it is because a pair of readings of one
    /// Chinese paragraph that disagree on every fourth character still
    /// describes the same paragraph, while two adjacent paragraphs of the
    /// same document rarely score above a third.
    static let pairingFloor = 0.4
    /// What an unmatched block costs. Small: leaving a block unmatched has to
    /// stay cheaper than forcing it onto text it has nothing to do with.
    static let gapPenalty = -0.05

    public static func align(
        _ left: [SourceBlock],
        _ right: [SourceBlock]
    ) -> [Pair] {
        if left.isEmpty {
            return right.map { Pair(left: [], right: [$0], similarity: 0) }
        }
        if right.isEmpty {
            return left.map { Pair(left: [$0], right: [], similarity: 0) }
        }

        enum Move {
            case pair
            case mergeRight
            case mergeLeft
            case skipLeft
            case skipRight
            case start
        }

        let rows = left.count + 1
        let columns = right.count + 1
        var score = [[Double]](
            repeating: [Double](repeating: 0, count: columns),
            count: rows
        )
        var from = [[Move]](
            repeating: [Move](repeating: .start, count: columns),
            count: rows
        )

        for row in 1..<rows {
            score[row][0] = score[row - 1][0] + gapPenalty
            from[row][0] = .skipLeft
        }
        for column in 1..<columns {
            score[0][column] = score[0][column - 1] + gapPenalty
            from[0][column] = .skipRight
        }

        for row in 1..<rows {
            for column in 1..<columns {
                var best = score[row - 1][column] + gapPenalty
                var move = Move.skipLeft

                let skipRight = score[row][column - 1] + gapPenalty
                if skipRight > best {
                    best = skipRight
                    move = .skipRight
                }

                let paired = score[row - 1][column - 1]
                    + reward(left[row - 1].text, right[column - 1].text)
                if paired > best {
                    best = paired
                    move = .pair
                }

                if column >= 2 {
                    let merged = score[row - 1][column - 2] + reward(
                        left[row - 1].text,
                        right[column - 2].text + right[column - 1].text
                    )
                    if merged > best {
                        best = merged
                        move = .mergeRight
                    }
                }

                if row >= 2 {
                    let merged = score[row - 2][column - 1] + reward(
                        left[row - 2].text + left[row - 1].text,
                        right[column - 1].text
                    )
                    if merged > best {
                        best = merged
                        move = .mergeLeft
                    }
                }

                score[row][column] = best
                from[row][column] = move
            }
        }

        var pairs: [Pair] = []
        var row = rows - 1
        var column = columns - 1
        while row > 0 || column > 0 {
            switch from[row][column] {
            case .pair:
                let a = left[row - 1]
                let b = right[column - 1]
                pairs.append(
                    Pair(
                        left: [a],
                        right: [b],
                        similarity: TextSimilarity.score(a.text, b.text)
                    )
                )
                row -= 1
                column -= 1
            case .mergeRight:
                let a = left[row - 1]
                let b = Array(right[(column - 2)...(column - 1)])
                pairs.append(
                    Pair(
                        left: [a],
                        right: b,
                        similarity: TextSimilarity.score(
                            a.text,
                            b.map(\.text).joined()
                        )
                    )
                )
                row -= 1
                column -= 2
            case .mergeLeft:
                let a = Array(left[(row - 2)...(row - 1)])
                let b = right[column - 1]
                pairs.append(
                    Pair(
                        left: a,
                        right: [b],
                        similarity: TextSimilarity.score(
                            a.map(\.text).joined(),
                            b.text
                        )
                    )
                )
                row -= 2
                column -= 1
            case .skipLeft:
                pairs.append(
                    Pair(left: [left[row - 1]], right: [], similarity: 0)
                )
                row -= 1
            case .skipRight:
                pairs.append(
                    Pair(left: [], right: [right[column - 1]], similarity: 0)
                )
                column -= 1
            case .start:
                row = 0
                column = 0
            }
        }
        return pairs.reversed()
    }

    /// Similarity, shifted so that a poor match scores worse than not
    /// matching at all. Without the shift the aligner pairs everything with
    /// everything, because any similarity above zero beats a penalty.
    static func reward(_ lhs: String, _ rhs: String) -> Double {
        TextSimilarity.score(lhs, rhs) - pairingFloor
    }
}
