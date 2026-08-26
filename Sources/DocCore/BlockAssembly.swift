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

        var blocks: [SourceBlock] = []
        for run in grouped {
            blocks.append(
                contentsOf: sentences(
                    in: run,
                    pageIndex: pageIndex,
                    medianHeight: median,
                    language: language,
                    from: blocks.count
                )
            )
        }
        return blocks
    }

    /// A run of wrapped lines, cut into sentences.
    ///
    /// This is the unit the rest of the app works in, and choosing it is not
    /// a detail. A recognizer and a vision-language model do not group a page
    /// the same way: on a court notice with even line spacing, Apple Vision
    /// returned two blocks — spacing is all it has to go on — while the model
    /// returned twenty-four, one per printed line. Nothing downstream can
    /// usefully compare two readings that disagree by a factor of twelve
    /// about what a block is; the alignment degenerates, the model's blocks
    /// match nothing, and the app ends up translating the reader that
    /// invents rather than the one that cannot.
    ///
    /// A sentence is the unit both can be brought to. It is also the right
    /// unit for everything downstream: it is what a translator needs to see
    /// at once, it is what a confidence score is worth attaching to, and it
    /// is small enough that a person checking a flagged block can find it on
    /// the page.
    ///
    /// Babelstaarnet arrived at the same unit from the other end — it
    /// assembles a sentence *across* wrapped lines, because bridging a single
    /// visual line handed readers fragments that began after the subject and
    /// stopped before the verb.
    public static func sentences(
        in run: [RecognizedLine],
        pageIndex: Int,
        medianHeight: Double,
        language: SourceLanguage,
        from order: Int
    ) -> [SourceBlock] {
        guard !run.isEmpty else { return [] }
        let runBox = run.dropFirst().reduce(run[0].box) { $0.union($1.box) }
        let runKind = classify(
            run,
            box: runBox,
            medianHeight: medianHeight,
            language: language
        )
        let confidence = run.map(\.confidence).reduce(0, +)
            / Double(run.count)
        let (joined, spans) = joinedWithSpans(run, language: language)

        func whole() -> [SourceBlock] {
            [
                SourceBlock(
                    pageIndex: pageIndex,
                    order: order,
                    box: runBox,
                    kind: runKind,
                    lines: run.map(\.text),
                    text: joined,
                    confidence: confidence
                )
            ]
        }

        let ranges = language.sentenceBoundary.sentenceRanges(in: joined)
        guard ranges.count > 1 else { return whole() }

        let source = joined as NSString
        var blocks: [SourceBlock] = []
        for range in ranges {
            let text = source.substring(with: range)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let covered = spans.filter {
                NSIntersectionRange($0.range, range).length > 0
            }
            guard let box = box(for: range, over: covered) else { continue }
            // A heading or a page number keeps its kind however many stops it
            // turned out to contain — those are facts about the whole run.
            // Being a list item is not: a run that opens with 一、 continues
            // into sentences that are not items themselves, and inheriting
            // the run's kind would bullet the paragraph after the list.
            let kind: BlockKind
            switch runKind {
            case .heading, .pageFurniture, .caption, .tableRow:
                kind = runKind
            case .paragraph, .listItem:
                kind = isListItem(text) ? .listItem : .paragraph
            }
            blocks.append(
                SourceBlock(
                    pageIndex: pageIndex,
                    order: order + blocks.count,
                    box: box,
                    kind: kind,
                    lines: covered.map { span in
                        source.substring(
                            with: NSIntersectionRange(span.range, range)
                        )
                    },
                    text: text,
                    confidence: confidence
                )
            )
        }
        return blocks.isEmpty ? whole() : blocks
    }

    public struct LineSpan {
        public let line: RecognizedLine
        /// Where this line's text sits in the joined run.
        public let range: NSRange
    }

    /// The run as one string, with each line's place in it, so a sentence
    /// range can be mapped back onto the page it was printed on.
    public static func joinedWithSpans(
        _ run: [RecognizedLine],
        language: SourceLanguage
    ) -> (String, [LineSpan]) {
        var joined = ""
        var spans: [LineSpan] = []
        for line in run {
            if !joined.isEmpty,
               needsSpace(after: joined, before: line.text, language: language) {
                joined += " "
            }
            let start = (joined as NSString).length
            joined += line.text
            let length = (joined as NSString).length - start
            spans.append(
                LineSpan(
                    line: line,
                    range: NSRange(location: start, length: length)
                )
            )
        }
        return (joined, spans)
    }

    /// The box a sentence occupies: the lines it is printed across, and where
    /// it shares a line with its neighbour, its share of that line.
    ///
    /// The share is taken by character count. In a script whose glyphs are
    /// all one width that is exact; on a Latin line it is an approximation,
    /// and it is the approximation the layout-preserving export needs so that
    /// two sentences sharing a line do not each erase the whole of it.
    public static func box(
        for range: NSRange,
        over spans: [LineSpan]
    ) -> BlockBox? {
        var box: BlockBox?
        for span in spans {
            let shared = NSIntersectionRange(span.range, range)
            guard shared.length > 0, span.range.length > 0 else { continue }
            let piece: BlockBox
            if shared.length == span.range.length {
                piece = span.line.box
            } else {
                let measure = Double(span.range.length)
                let from = Double(shared.location - span.range.location)
                    / measure
                let to = Double(NSMaxRange(shared) - span.range.location)
                    / measure
                piece = BlockBox(
                    x: span.line.box.x + span.line.box.width * from,
                    y: span.line.box.y,
                    width: span.line.box.width * (to - from),
                    height: span.line.box.height
                )
            }
            box = box.map { $0.union(piece) } ?? piece
        }
        return box
    }

    static func needsSpace(
        after joined: String,
        before next: String,
        language: SourceLanguage
    ) -> Bool {
        if language.isSpaceSeparated { return true }
        guard let previous = joined.last, let first = next.first else {
            return false
        }
        return previous.isLatinWordCharacter && first.isLatinWordCharacter
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
            if continuesLine(previous, line) {
                current.append(line)
                groups[groups.count - 1] = current
            } else {
                groups.append([line])
            }
        }
        return groups
    }

    /// Whether two lines belong to the same run of text.
    ///
    /// Taken from Babelstaarnet, whose comment says it best: three things
    /// separate a wrapped line from the next thing on the page — a gap no
    /// wider than a line, a column the text shares, and type of the same
    /// size. The last one is what keeps a heading out of the paragraph
    /// beneath it, where the first two alone would have accepted it, and it
    /// is the one this project was missing.
    public static func continuesLine(
        _ upper: RecognizedLine,
        _ lower: RecognizedLine
    ) -> Bool {
        let upperBox = upper.box
        let lowerBox = lower.box
        guard upperBox.height > 0, lowerBox.height > 0 else { return false }

        let lineHeight = Swift.max(upperBox.height, lowerBox.height)
        let gap = lowerBox.minY - upperBox.maxY
        guard gap <= lineHeight * 1.25, gap >= -lineHeight * 0.6 else {
            return false
        }

        guard lowerBox.horizontalOverlap(with: upperBox) >= 0.4 else {
            return false
        }

        // Vision reports a box that follows whichever ascenders and
        // descenders the line happens to contain, so same-size type still
        // varies by a fifth or so either way.
        let ratio = upperBox.height / lowerBox.height
        return ratio >= 0.7 && ratio <= 1.45
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
