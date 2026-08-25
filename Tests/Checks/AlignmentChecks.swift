import DocAgents
import DocCore
import Foundation

/// Matching two readers' paragraphs when only one of them has geometry.
func runAlignmentChecks(_ report: Report) {
    report.begin("alignment")

    let left = [
        block("第一段内容在这里。", order: 0),
        block("第二段内容在这里。", order: 1),
        block("第三段内容在这里。", order: 2)
    ]

    // Identical readings pair straight through.
    let same = BlockAlignment.align(left, left)
    report.equal(same.count, 3, "identical readings pair one to one")
    report.expect(
        same.allSatisfy { $0.similarity > 0.99 },
        "identical blocks score as identical"
    )

    // One reader merged two paragraphs into one. Without the merge
    // transition this knocks every later block out of step.
    let merged = [
        block("第一段内容在这里。第二段内容在这里。", order: 0),
        block("第三段内容在这里。", order: 1)
    ]
    let withMerge = BlockAlignment.align(left, merged)
    report.expect(
        withMerge.allSatisfy { !$0.left.isEmpty && !$0.right.isEmpty },
        "a merged paragraph leaves no block unmatched"
    )
    report.expect(
        withMerge.contains { $0.left.count == 2 || $0.right.count == 2 },
        "the merge is represented as a two-to-one pair"
    )
    report.expect(
        withMerge.last?.similarity ?? 0 > 0.99,
        "blocks after a merge stay in step"
    )

    // A reader that missed a block leaves a gap rather than shifting
    // everything after it.
    let missing = [left[0], left[2]]
    let withGap = BlockAlignment.align(left, missing)
    report.equal(withGap.count, 3, "a missing block becomes a gap")
    report.expect(
        withGap.contains { $0.right.isEmpty && $0.left.first?.text == left[1].text },
        "the gap lands on the block that was missed"
    )
    report.expect(
        withGap.last?.similarity ?? 0 > 0.99,
        "the block after a gap still matches"
    )

    // Unrelated text is not forced into a pair.
    let unrelated = [block("完全不同的内容与前文无关。", order: 0)]
    let noPair = BlockAlignment.align([left[0]], unrelated)
    report.expect(
        noPair.allSatisfy { $0.left.isEmpty || $0.right.isEmpty },
        "text with nothing in common is left unpaired"
    )

    report.begin("similarity")
    report.near(
        TextSimilarity.score("本协议自2024年生效", "本协议自2024年生效"),
        1,
        0.001,
        "identical strings score 1"
    )
    // One misread character in a dozen is a small disagreement, not a total
    // one — the property a word-level comparison of Chinese cannot have.
    let oneOff = TextSimilarity.score(
        "本协议自二零二四年三月生效",
        "本协议自二零二四年三日生效"
    )
    report.expect(
        oneOff > 0.85 && oneOff < 1,
        "one wrong character is a small disagreement (got \(oneOff))"
    )
    report.equal(
        TextSimilarity.score("", ""),
        1,
        "two empty readings agree"
    )
    report.equal(
        TextSimilarity.score("内容", ""),
        0,
        "text against nothing scores 0"
    )
}
