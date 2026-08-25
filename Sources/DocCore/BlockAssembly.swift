import Foundation

/// One recognized line, in the shape the assembler needs and independent of
/// which engine produced it.
public struct RecognizedLine: Sendable {
    public let text: String
    /// Normalized to the page, origin top left.
    public let box: BlockBox
    public let confidence: Double

    public init(text: String, box: BlockBox, confidence: Double) {
        self.text = text
        self.box = box
        self.confidence = confidence
    }
}

/// Lines into blocks, and blocks into reading order.
///
/// This is the part of OCR that decides what a *paragraph* is, and it matters
/// more than it looks: everything downstream translates a block at a time, so
/// a paragraph split in three is three translations with no shared context,
/// and two columns merged into one is a translation of interleaved halves of
/// two different sentences.
///
/// It is written as pure functions over boxes so the whole of it can be
/// checked against fabricated layouts, with no image, no Vision, and no
/// model.
public enum BlockAssembly {
    public static func blocks(
        from lines: [RecognizedLine],
        pageIndex: Int,
        language: SourceLanguage
    ) -> [SourceBlock] {
        let kept = lines.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !kept.isEmpty else { return [] }

        let ordered = readingOrder(of: kept)
        let median = medianHeight(of: kept)
        let grouped = group(ordered, medianHeight: median)

        return grouped.enumerated().map { index, group in
            let box = group.dropFirst().reduce(group[0].box) {
                $0.union($1.box)
            }
            let text = join(group.map(\.text), language: language)
            return SourceBlock(
                pageIndex: pageIndex,
                order: index,
                box: box,
                kind: classify(
                    group,
                    box: box,
                    medianHeight: median,
                    language: language
                ),
                lines: group.map(\.text),
                text: text,
                confidence: group.map(\.confidence).reduce(0, +)
                    / Double(group.count)
            )
        }
    }

    // MARK: - Reading order

    /// Single column unless the page shows a gutter: a vertical band with no
    /// text in it, wide enough not to be word spacing, with real content on
    /// both sides.
    ///
    /// Detecting this is not optional politeness for two-column layouts. Read
    /// top-to-bottom across a two-column page, every line of the left column
    /// is followed by a line of the right one, and the "paragraph" handed to
    /// the translator is two unrelated half-sentences alternating. The result
    /// reads like a model failure and is a layout failure.
    public static func readingOrder(of lines: [RecognizedLine]) -> [RecognizedLine] {
        guard let gutter = gutter(in: lines) else {
            return lines.sorted { $0.box.minY < $1.box.minY }
        }

        // A line crossing the gutter belongs to neither column — a banner
        // headline, or a rule — and separates what is above it from what is
        // below.
        var bands: [[RecognizedLine]] = [[]]
        for line in lines.sorted(by: { $0.box.minY < $1.box.minY }) {
            if line.box.minX < gutter, line.box.maxX > gutter {
                bands.append([line])
                bands.append([])
            } else {
                bands[bands.count - 1].append(line)
            }
        }

        return bands.flatMap { band -> [RecognizedLine] in
            let left = band.filter { $0.box.maxX <= gutter }
                .sorted { $0.box.minY < $1.box.minY }
            let right = band.filter { $0.box.minX >= gutter }
                .sorted { $0.box.minY < $1.box.minY }
            let spanning = band.filter {
                $0.box.minX < gutter && $0.box.maxX > gutter
            }
            return spanning + left + right
        }
    }

    /// The x position of a gutter, if the page has one.
    public static func gutter(in lines: [RecognizedLine]) -> Double? {
        guard lines.count >= 6 else { return nil }
        let bins = 100
        var occupied = [Bool](repeating: false, count: bins)
        for line in lines {
            let from = max(0, Int(line.box.minX * Double(bins)))
            let to = min(bins - 1, Int(line.box.maxX * Double(bins)))
            guard from <= to else { continue }
            for bin in from...to { occupied[bin] = true }
        }
        guard let first = occupied.firstIndex(of: true),
              let last = occupied.lastIndex(of: true),
              last - first > 20 else { return nil }

        var bestStart: Int?
        var best: Range<Int>?
        for bin in first...last {
            if occupied[bin] {
                if let start = bestStart {
                    let run = start..<bin
                    if run.count > (best?.count ?? 0) { best = run }
                    bestStart = nil
                }
            } else if bestStart == nil {
                bestStart = bin
            }
        }
        // At least 4% of the page wide, and not at either margin: a gap at
        // the edge is a margin, and a narrow one is the space between two
        // words on a sparse line.
        guard let run = best, run.count >= 4 else { return nil }
        let gutter = Double(run.lowerBound + run.count / 2) / Double(bins)
        let left = lines.filter { $0.box.maxX <= gutter }
        let right = lines.filter { $0.box.minX >= gutter }
        guard left.count >= 3, right.count >= 3 else { return nil }
        return gutter
    }

    // MARK: - Grouping

    public static func group(
        _ lines: [RecognizedLine],
        medianHeight: Double
    ) -> [[RecognizedLine]] {
        var groups: [[RecognizedLine]] = []
        for line in lines {
            guard var current = groups.last, let previous = current.last else {
                groups.append([line])
                continue
            }
            let gap = line.box.minY - previous.box.maxY
            let overlap = line.box.horizontalOverlap(with: previous.box)
            // A gap of more than about one blank line ends a paragraph, and
            // so does a line that does not sit under the previous one at all.
            // The leading multiple is generous because line spacing varies
            // more between documents than between paragraphs within one.
            let continues = gap < medianHeight * 0.9 && overlap > 0.35
            if continues {
                current.append(line)
                groups[groups.count - 1] = current
            } else {
                groups.append([line])
            }
        }
        return groups
    }

    public static func medianHeight(of lines: [RecognizedLine]) -> Double {
        let heights = lines.map(\.box.height).sorted()
        guard !heights.isEmpty else { return 0.02 }
        return heights[heights.count / 2]
    }

    // MARK: - Classification

    public static func classify(
        _ lines: [RecognizedLine],
        box: BlockBox,
        medianHeight: Double,
        language: SourceLanguage
    ) -> BlockKind {
        let text = lines.map(\.text).joined()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Running heads and page numbers: short, alone, and pinned to an
        // edge. Worth naming because translating them costs a model call per
        // page to turn "第 3 页" into "Page 3".
        if trimmed.count <= 24,
           lines.count == 1,
           box.maxY > 0.93 || box.minY < 0.05 {
            return .pageFurniture
        }

        if isListItem(trimmed) { return .listItem }

        // A heading does not end in a full stop. Without this, any short
        // sentence set a little larger than the body — a standfirst, an
        // emphasized clause, the one line of a notice that matters — comes
        // out as a heading, and the translated document sets it in bold at
        // the wrong size. The stops are the pack's, because what ends a
        // sentence is a fact about the writing system: a Chinese one ends at
        // 。, not at a period.
        let endsASentence = trimmed.last.map {
            language.sentenceTerminators.contains($0)
        } ?? false

        // Bigger type than the page's body, and short enough to be a title
        // rather than a paragraph set in large type.
        if lines.count <= 2,
           !endsASentence,
           box.height / Double(lines.count) > medianHeight * 1.3,
           trimmed.count <= 60 {
            return .heading
        }

        return .paragraph
    }

    public static func isListItem(_ text: String) -> Bool {
        let markers = ["•", "·", "‧", "-", "—", "*", "▪", "◦"]
        if let first = text.first, markers.contains(String(first)) {
            return true
        }
        // Enumerations: `1.` `1)` `(1)` `（一）` `一、` `第一条`
        let patterns = [
            "^\\d+[.)、]",
            "^[（(]\\s*[0-9一二三四五六七八九十]+\\s*[)）]",
            "^[一二三四五六七八九十百]+[、.]",
            "^第[0-9一二三四五六七八九十百]+[条章节款项]"
        ]
        return patterns.contains { pattern in
            text.range(of: pattern, options: .regularExpression) != nil
        }
    }

    // MARK: - Joining

    /// Lines of one paragraph into one string.
    ///
    /// A line break inside a Chinese paragraph is a typesetting artifact, not
    /// a space: joining with one would insert a word boundary the original
    /// does not have, in a script that does not use them. But a line that
    /// breaks in the middle of a Latin phrase — a name, a product code, a URL
    /// — does need its space back, so the join looks at the two characters
    /// either side rather than at the language alone.
    public static func join(_ lines: [String], language: SourceLanguage) -> String {
        guard var result = lines.first else { return "" }
        for line in lines.dropFirst() {
            let previous = result.last
            let next = line.first
            let needsSpace: Bool
            if language.isSpaceSeparated {
                needsSpace = true
            } else if let previous, let next {
                needsSpace = previous.isLatinWordCharacter
                    && next.isLatinWordCharacter
            } else {
                needsSpace = false
            }
            result += (needsSpace ? " " : "") + line
        }
        return result
    }
}

extension Character {
    var isLatinWordCharacter: Bool {
        isASCII && (isLetter || isNumber)
    }
}
