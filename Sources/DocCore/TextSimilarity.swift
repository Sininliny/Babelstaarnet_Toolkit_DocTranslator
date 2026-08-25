import Foundation

/// How alike two readings of the same block are.
///
/// Character-level rather than word-level, because the first language this
/// runs on does not put spaces between words: a word-level comparison of two
/// Chinese readings compares two single "words" and answers 0 or 1. Per
/// character it degrades gracefully, which is what the reconciler needs — one
/// misread glyph in forty should read as a small disagreement, not a total
/// one.
public enum TextSimilarity {
    /// Long blocks are truncated before comparison. The cost is quadratic in
    /// length, a page of dense text can reach a few thousand characters, and
    /// two readings that agree on their first two thousand characters and
    /// diverge after are not a case this decision needs to be right about —
    /// the agreement score is a routing signal, not a diff.
    static let comparisonLimit = 2_000

    /// 1 when identical, 0 when nothing matches.
    public static func score(_ lhs: String, _ rhs: String) -> Double {
        let a = Array(lhs.prefix(comparisonLimit))
        let b = Array(rhs.prefix(comparisonLimit))
        if a.isEmpty && b.isEmpty { return 1 }
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        if a == b { return 1 }
        let distance = editDistance(a, b)
        let longest = max(a.count, b.count)
        return max(0, 1 - Double(distance) / Double(longest))
    }

    /// Levenshtein over two rows rather than a full matrix: the score is all
    /// anyone reads, and a page of blocks would otherwise allocate megabytes
    /// to produce a single number per block.
    public static func editDistance(
        _ a: [Character],
        _ b: [Character]
    ) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let substitution = previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                current[j] = min(
                    previous[j] + 1,
                    current[j - 1] + 1,
                    substitution
                )
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    /// The positions where two readings differ, as spans of the first one.
    /// This is what the interface shows when it opens a disagreement: the
    /// three characters the two readers read differently, not the paragraph
    /// they sit in.
    public static func differingRuns(
        _ lhs: String,
        _ rhs: String
    ) -> [Range<String.Index>] {
        let a = Array(lhs)
        let b = Array(rhs)
        var runs: [Range<String.Index>] = []
        // A common prefix and suffix cover the ordinary case — one misread
        // glyph in the middle — without paying for an alignment matrix.
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < a.count - prefix,
              suffix < b.count - prefix,
              a[a.count - 1 - suffix] == b[b.count - 1 - suffix] {
            suffix += 1
        }
        guard prefix < a.count - suffix else { return runs }
        let start = lhs.index(lhs.startIndex, offsetBy: prefix)
        let end = lhs.index(lhs.endIndex, offsetBy: -suffix)
        runs.append(start..<end)
        return runs
    }
}
