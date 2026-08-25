import AppKit
import CoreGraphics
import CoreText
import DocCore
import Foundation

/// The document again, looking like itself, in English.
///
/// This is the output most people picture when they ask for a document to be
/// translated: the same form, the same table, the same letterhead and the
/// same red seal, with the words they could not read now in words they can.
/// It is also the output that can lie most convincingly, so three rules hold
/// it down:
///
/// **Only text with a place on the page is replaced.** A block the character
/// recognizer found has a box, measured on the page. A block that only the
/// vision-language model reported has no geometry at all, and painting it
/// somewhere plausible would put a sentence on the page that nothing measured
/// — so those blocks are left out of this export entirely and stay in the
/// side-by-side one, where they are visible as what they are.
///
/// **Everything not replaced is left exactly as it was.** Page numbers,
/// stamps, signatures, photographs, logos, rules, and anything the readers
/// did not agree was text: untouched pixels. The English is drawn over a
/// patch the size of the original text and nothing wider.
///
/// **A run of type is set at one size.** Every block here could be fitted to
/// its own box, and every one of them would be individually correct: the
/// heading shrunk to a caption because its English ran long, the row above it
/// at twice the size of the row below because two words fell into a wide
/// cell. A page set that way is unreadable in a particular way — nothing on
/// it is wrong, and none of it can be scanned down. So the size is settled
/// for a run of type and not for a block, and a block that cannot live at its
/// run's size is the only one that changes.
public enum LayoutPreservingPDF {
    public enum Failure: LocalizedError {
        case couldNotStartPDF
        case noPages

        public var errorDescription: String? {
            switch self {
            case .couldNotStartPDF:
                return "The translated PDF could not be started."
            case .noPages:
                return "There were no pages to write."
            }
        }
    }

    /// How much larger than the measured box the erased patch is, as a share
    /// of the box's height. Recognizers report a tight box around the glyphs
    /// and antialiasing puts a grey fringe just outside it, which reads as a
    /// shadow of the original text under the English.
    static let bleed = 0.12
    /// Below this the English is unreadable, so it is allowed to run past the
    /// bottom of the original box rather than shrink further. A translation
    /// that overflows can be read; one set at three points cannot.
    static let minimumTextSize: CGFloat = 6.5
    /// CoreText's frame-size suggestion is asked for an unbounded height, and
    /// "unbounded" has to be a large finite number. Given
    /// `.greatestFiniteMagnitude` it returns the height of a single line, so
    /// every block appears to fit at any size and nothing is ever shrunk —
    /// which looks exactly like a fitting algorithm that does not work.
    static let unbounded: CGFloat = 1_000_000
    /// A single line of type stands in a box about this much taller than its
    /// point size, and n lines stand in a box of one of those plus n-1
    /// leadings. Both numbers are here to read a type size back off a box,
    /// which is the only record of the original there is.
    static let lineBox: CGFloat = 1.12
    static let leading: CGFloat = 1.45
    /// Two blocks belong to the same run of type when the lines they were
    /// printed on were within a quarter of each other in height. Wider than
    /// the variation a recognizer introduces measuring the same size twice,
    /// narrower than the step between a heading and the text under it.
    static let sameRun = 1.25
    /// And nothing that is not a heading is set more than this much larger
    /// than the page's ordinary type, however tall its box was. A box far
    /// taller than the run around it is not large type; it is two rows the
    /// reader merged into one block, and setting three words at the height of
    /// three rows prints them over everything nearby.
    static let largestBody: CGFloat = 1.4

    public static func render(
        _ document: TranslatedDocument,
        pages provider: any PageProvider
    ) throws -> Data {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data) else {
            throw Failure.couldNotStartPDF
        }
        guard !document.pages.isEmpty else { throw Failure.noPages }

        var firstBox = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let context = CGContext(
            consumer: consumer,
            mediaBox: &firstBox,
            [
                kCGPDFContextTitle as String:
                    document.source.displayName + " (English)",
                kCGPDFContextCreator as String: "Læsesalen"
            ] as CFDictionary
        ) else {
            throw Failure.couldNotStartPDF
        }

        for page in document.pages {
            guard let image = try? provider.page(at: page.index) else {
                continue
            }
            // The page's own size, so the translated PDF prints on the same
            // paper as the original.
            let size = image.pointSize.width > 0 && image.pointSize.height > 0
                ? image.pointSize
                : image.pixelSize
            var box = CGRect(origin: .zero, size: size)
            context.beginPage(mediaBox: &box)
            context.draw(image.image, in: box)

            // Every patch, and then every line of English.
            //
            // A patch is the size of the text it replaces plus a fringe, and
            // on a form the fringe of one row reaches into the next. Erasing
            // and painting one block at a time means the second row's patch
            // lands on the first row's English, and the row that disappears
            // is one that was already right — a blank line in the middle of
            // a translated table with nothing to say it was ever there. So
            // the page is erased first and written on afterwards.
            let placed = placements(for: page.blocks, on: image, in: box)
            for placement in placed {
                context.setFillColor(placement.background)
                context.fill(placement.patch)
            }
            for placement in placed {
                CTFrameDraw(placement.text, context)
            }
            context.endPage()
        }

        context.closePDF()
        return data as Data
    }

    /// A block, fitted and positioned, waiting for the page to be erased.
    private struct Placement {
        let patch: CGRect
        let background: CGColor
        let text: CTFrame
    }

    private static func placements(
        for blocks: [TranslatedBlock],
        on page: PageImage,
        in box: CGRect
    ) -> [Placement] {
        let drawable = blocks.filter { isDrawable($0, in: box) }
        guard !drawable.isEmpty else { return [] }
        // Sized against every block on the page, not only the ones being
        // replaced. A figure left as printed pixels is still a line of type,
        // and on a form most of them are: leave them out and the run of type
        // is settled by the labels alone.
        let sizes = typeSizes(for: blocks, in: box)

        return drawable.map { block in
            // Among *all* the blocks, not only the ones being replaced. The
            // figure beside a label is left as printed pixels precisely
            // because it needed no translating, and something left alone is
            // still in the way.
            placement(
                for: block,
                among: blocks,
                setAt: sizes[block.id] ?? minimumTextSize,
                on: page,
                in: box
            )
        }
    }

    /// Whether this block is one this export is allowed to draw at all.
    static func isDrawable(_ block: TranslatedBlock, in box: CGRect) -> Bool {
        let english = block.text.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !english.isEmpty else { return false }
        // Untranslated by design — a page number, or a block the translator
        // handed back unchanged. Its original pixels are already right.
        guard english != block.source.text else { return false }
        // No geometry: see the note at the top of this file.
        guard block.source.box != .full else { return false }
        let measured = rect(for: block.source.box, in: box)
        return measured.width > 4 && measured.height > 4
    }

    private static func placement(
        for block: TranslatedBlock,
        among neighbours: [TranslatedBlock],
        setAt runSize: CGFloat,
        on page: PageImage,
        in box: CGRect
    ) -> Placement {
        let english = block.text.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let measured = rect(for: block.source.box, in: box)
        let space = space(for: block, among: neighbours, in: box)
        let colours = PageColours.sample(
            page.image,
            box: pixelRect(for: block.source.box, in: page)
        )
        let floor = roomBelow(block, among: neighbours, within: space, in: box)

        let attributed = attributedText(
            english,
            heading: isHeading(block, among: neighbours, in: box),
            colour: colours.ink,
            centred: isCentred(block, among: neighbours, in: box),
            within: space.size,
            over: space.minY - floor,
            setAt: runSize
        )
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let laid = laidOut(framesetter, in: space, floor: floor)
        let text = CTFramesetterCreateFrame(
            framesetter,
            CFRangeMake(0, 0),
            CGPath(rect: laid, transform: nil),
            nil
        )

        // The patch covers the Chinese and the English and nothing else.
        //
        // Erasing the whole space a block was *allowed* is what takes the
        // rule between two columns off the page: the block was allowed the
        // width beside it, used a third of it, and the paint went over all
        // of it. What has to disappear is the text being replaced; what has
        // to be covered is the text replacing it.
        let painted = inked(text).union(measured)
        let patch = painted.insetBy(
            dx: -measured.height * bleed,
            dy: -measured.height * bleed
        ).intersection(box)

        return Placement(
            patch: patch,
            background: colours.background,
            text: text
        )
    }

    // MARK: - The run of type

    /// The size each block is set at, settled for the page rather than for
    /// the block.
    ///
    /// Blocks are grouped by the height of the lines they were printed on,
    /// which is the only surviving record of how large the original type was.
    /// Each group is then set at one size — the size that group's type was —
    /// and a block whose English will not fit at that size is shrunk on its
    /// own. The asymmetry is the point: a block may be smaller than its run
    /// because it has to be, and may never be larger because it happens to
    /// have room.
    ///
    /// Headings are grouped apart from everything else, because a heading
    /// that is the same height as the paragraph under it should still be able
    /// to differ from it, and because a run that mixed the two would set both
    /// at whichever won the median.
    public static func typeSizes(
        for blocks: [TranslatedBlock],
        in box: CGRect
    ) -> [UUID: CGFloat] {
        let implied = blocks.reduce(into: [UUID: CGFloat]()) { sizes, block in
            sizes[block.id] = impliedTypeSize(of: block, in: box)
        }
        let headings = blocks.filter { isHeading($0, among: blocks, in: box) }
            .map(\.id)
        let body = median(
            blocks.filter { !headings.contains($0.id) }
                .compactMap { implied[$0.id] }
        ) ?? median(Array(implied.values)) ?? minimumTextSize

        var sizes: [UUID: CGFloat] = [:]
        for heading in [true, false] {
            let group = blocks.filter {
                headings.contains($0.id) == heading
            }
            for run in runs(of: group, sizes: implied) {
                let size = median(run.compactMap { implied[$0.id] })
                    ?? minimumTextSize
                for block in run {
                    sizes[block.id] = max(
                        minimumTextSize,
                        heading ? size : min(size, body * largestBody)
                    )
                }
            }
        }
        return sizes
    }

    /// Blocks split into runs of type: sorted by the height of their lines
    /// and cut wherever the next one is more than a quarter taller than the
    /// last.
    private static func runs(
        of blocks: [TranslatedBlock],
        sizes: [UUID: CGFloat]
    ) -> [[TranslatedBlock]] {
        let sorted = blocks.sorted {
            (sizes[$0.id] ?? 0) < (sizes[$1.id] ?? 0)
        }
        var runs: [[TranslatedBlock]] = []
        for block in sorted {
            guard let last = runs.last?.last,
                  let previous = sizes[last.id],
                  let size = sizes[block.id],
                  size <= previous * sameRun else {
                runs.append([block])
                continue
            }
            runs[runs.count - 1].append(block)
        }
        return runs
    }

    /// The size the original type was, read off the box it filled.
    ///
    /// A box is not a type size. It is n lines of type plus the n-1 leadings
    /// between them, and a block reporting three lines in a box three lines
    /// tall was set at a third of it. `lineCount` is the only record of that,
    /// which is why the reconciler carries it through.
    public static func impliedTypeSize(
        of block: TranslatedBlock,
        in box: CGRect
    ) -> CGFloat {
        let measured = rect(for: block.source.box, in: box)
        let lines = CGFloat(max(1, block.source.lineCount))
        return measured.height / ((lines - 1) * leading + lineBox)
    }

    private static func median(_ values: [CGFloat]) -> CGFloat? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    // MARK: - Setting the type

    /// The English, set at its run's size, or smaller where it must be.
    ///
    /// What it has to fit into is the box plus the empty paper under it, not
    /// the box alone. A box is measured around glyphs, so it comes back a
    /// point or two taller on one row than on the next for reasons that have
    /// nothing to do with the type in it — and a block set at its run's size
    /// stands very slightly taller than the box the Chinese stood in, because
    /// a Latin line carries ascenders and descenders a Chinese one does not.
    /// Fitted to the box alone, every second row of a table shrinks a step
    /// for no reason a reader can see, and the run of type this export exists
    /// to hold together comes apart one row at a time. Measured against the
    /// paper as well, a row keeps its size, and a label whose English really
    /// is too long to fit takes a second line of the gap or, if there is no
    /// gap, gets smaller.
    ///
    /// The room below is what a collision would cost, so the same number
    /// bounds this as bounds the overflow itself: whatever is printed under
    /// the block.
    private static func attributedText(
        _ text: String,
        heading: Bool,
        colour: CGColor,
        centred: Bool,
        within size: CGSize,
        over room: CGFloat,
        setAt runSize: CGFloat
    ) -> NSAttributedString {
        // Shrinking is the only direction, and it is the normal case rather
        // than the exception: English set in a Latin face is longer than the
        // Chinese it came from, and the space available was measured for the
        // Chinese.
        let available = size.height + max(0, room)
        var pointSize = max(minimumTextSize, min(72, runSize))
        var best = attributed(
            text,
            heading: heading,
            size: pointSize,
            colour: colour,
            centred: centred
        )
        while pointSize > minimumTextSize {
            let framesetter = CTFramesetterCreateWithAttributedString(best)
            let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
                framesetter,
                CFRangeMake(0, 0),
                nil,
                CGSize(width: size.width, height: unbounded),
                nil
            )
            if suggested.height <= available { break }
            pointSize = max(minimumTextSize, pointSize - max(0.5, pointSize * 0.08))
            best = attributed(
                text,
                heading: heading,
                size: pointSize,
                colour: colour,
                centred: centred
            )
        }
        return best
    }

    private static func attributed(
        _ text: String,
        heading: Bool,
        size: CGFloat,
        colour: CGColor,
        centred: Bool
    ) -> NSAttributedString {
        let weight: CTFontSymbolicTraits = heading ? .traitBold : []
        var font = CTFontCreateWithName(
            "HelveticaNeue" as CFString,
            size,
            nil
        )
        if weight.contains(.traitBold),
           let bold = CTFontCreateCopyWithSymbolicTraits(
            font,
            size,
            nil,
            .traitBold,
            .traitBold
           ) {
            font = bold
        }

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = centred ? .center : .left
        paragraph.lineBreakMode = .byWordWrapping
        // Slightly tight: the English has to live in a space that was
        // measured for something denser.
        paragraph.lineHeightMultiple = 0.95

        return NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: colour,
                .paragraphStyle: paragraph
            ]
        )
    }

    /// Where the English sits inside the space the Chinese had.
    ///
    /// Text shorter than its box is centred in it. CoreText sets from the top
    /// of a frame, so a label set at its run's size in a cell measured a
    /// little taller starts above the figure printed beside it, and a table
    /// whose every row is a line or two out of true reads as a page that has
    /// slipped — the same fault as mismatched type sizes and from the same
    /// cause, each block correct against its own box.
    ///
    /// Text taller than its box runs downward instead of being clipped: a
    /// translation that overflows can be read and one that is silently cut
    /// cannot. It stops at whatever is printed underneath.
    static func laidOut(
        _ framesetter: CTFramesetter,
        in space: CGRect,
        floor: CGFloat
    ) -> CGRect {
        let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRangeMake(0, 0),
            nil,
            CGSize(width: space.width, height: unbounded),
            nil
        )
        guard suggested.height > space.height else {
            return CGRect(
                x: space.minX,
                y: space.minY + (space.height - suggested.height) / 2,
                width: space.width,
                height: suggested.height
            )
        }
        return CGRect(
            x: space.minX,
            y: max(floor, space.maxY - suggested.height),
            width: space.width,
            height: min(suggested.height, space.maxY - floor)
        )
    }

    /// What a laid-out frame will actually put ink on, which is narrower than
    /// the frame whenever the text did not need all the room it was allowed.
    private static func inked(_ frame: CTFrame) -> CGRect {
        let lines = (CTFrameGetLines(frame) as NSArray) as? [CTLine] ?? []
        guard !lines.isEmpty else { return .null }
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRangeMake(0, 0), &origins)
        let path = CTFrameGetPath(frame).boundingBox

        var union = CGRect.null
        for (index, line) in lines.enumerated() {
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            let width = CGFloat(
                CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
            )
            let origin = origins[index]
            union = union.union(
                CGRect(
                    x: path.minX + origin.x,
                    y: path.minY + origin.y - descent,
                    width: width,
                    height: ascent + descent
                )
            )
        }
        return union
    }

    // MARK: - The space a block may use

    /// The box the Chinese filled, widened into whatever empty paper is
    /// beside it.
    ///
    /// Without this every block is squeezed into the width of the Chinese it
    /// came from, and because English expands by different amounts in
    /// different blocks, each ends up at its own type size — a heading at
    /// half the size of the paragraph under it, every block individually
    /// "correct" and the page as a whole wrong. A ten-character Chinese
    /// heading becomes forty English characters; on a page with a wide right
    /// margin, a typesetter would simply set it wider.
    ///
    /// Two things stop the widening, and a form needs both. On the block's
    /// own lines, anything that starts to the right of where it starts is in
    /// the way — whether or not it starts clear of where the block ends,
    /// because two cells of a table row are measured a hair apart or a hair
    /// overlapping depending on the scan, and a rule that only recognizes the
    /// clear case lets a label run straight through the figure beside it.
    /// Off its lines, anything that begins clear of the block is the edge of
    /// the next column: the empty half of a two-column form is not empty
    /// paper, and a label that runs into it has crossed the rule between
    /// them. The last cell in a row has nothing beside it on its own lines
    /// and would otherwise cross the page.
    public static func space(
        for block: TranslatedBlock,
        among neighbours: [TranslatedBlock],
        in box: CGRect
    ) -> CGRect {
        let measured = rect(for: block.source.box, in: box)
        let measure = measure(of: neighbours, in: box)
        var left = min(measure.left, measured.minX)
        var right = max(measure.right, measured.maxX)
        let gap = measured.height * 0.35

        for other in neighbours where other.id != block.id {
            let rect = rect(for: other.source.box, in: box)
            let sharesLines = rect.minY < measured.maxY
                && rect.maxY > measured.minY
            if sharesLines {
                if rect.minX > measured.minX {
                    right = min(right, rect.minX - gap)
                }
                if rect.maxX < measured.maxX {
                    left = max(left, rect.maxX + gap)
                }
            } else if other.source.kind != .pageFurniture {
                // A page number in the middle of the foot is not the edge of
                // a column, and treating it as one narrows every short block
                // on the page to the width of the running head.
                if rect.minX >= measured.maxX {
                    right = min(right, rect.minX - gap)
                }
                if rect.maxX <= measured.minX {
                    left = max(left, rect.maxX + gap)
                }
            }
        }
        right = max(right, measured.maxX)
        left = min(left, measured.minX)

        // Centred text widens both ways or it stops being centred: given the
        // room to its right alone, a centred heading is reset in the middle
        // of the empty paper beside it rather than in the middle of the page.
        guard isCentred(block, among: neighbours, in: box) else {
            return CGRect(
                x: measured.minX,
                y: measured.minY,
                width: right - measured.minX,
                height: measured.height
            )
        }
        let half = min(measured.midX - left, right - measured.midX)
        return CGRect(
            x: measured.midX - half,
            y: measured.minY,
            width: half * 2,
            height: measured.height
        )
    }

    /// How far down a block may run before it would collide with the next
    /// thing printed under it.
    public static func roomBelow(
        _ block: TranslatedBlock,
        among neighbours: [TranslatedBlock],
        within space: CGRect,
        in box: CGRect
    ) -> CGFloat {
        let measured = rect(for: block.source.box, in: box)
        var floor = box.minY
        for other in neighbours where other.id != block.id {
            let rect = rect(for: other.source.box, in: box)
            // Against the space, not the measured box: a block that borrowed
            // the width beside it can now run into something that was never
            // underneath the Chinese.
            let sharesColumn = rect.minX < space.maxX && rect.maxX > space.minX
            // A neighbour whose top edge is below this block's middle is
            // under it. Requiring it to clear the box entirely is the same
            // mistake as the one to the right — rows in a dense table are
            // measured overlapping as often as not, and a floor that misses
            // the next row lets a two-line translation print over it.
            guard sharesColumn, rect.maxY <= measured.midY else { continue }
            floor = max(floor, rect.maxY)
        }
        // Never above the block's own box, however the neighbours were
        // measured: a floor inside the box would shorten the frame and clip
        // text that fitted.
        return min(floor, measured.minY)
    }

    /// The page's own text measure — the left and right margins the printer
    /// used, which is not the paper's edge.
    private static func measure(
        of blocks: [TranslatedBlock],
        in box: CGRect
    ) -> (left: CGFloat, right: CGFloat) {
        let rects = blocks.map { rect(for: $0.source.box, in: box) }
        return (
            rects.map(\.minX).min() ?? box.minX,
            rects.map(\.maxX).max() ?? box.maxX
        )
    }

    /// Centred text stays centred. A title that was in the middle of a
    /// letterhead and comes back flush left looks like a different document.
    ///
    /// A centred title has its lines to itself, and that is the test, because
    /// position alone cannot tell one from a table cell: on a form, every
    /// cell near the gutter is near the middle of the paper. Read by position
    /// alone, half a table is declared centred, and each of those cells is
    /// then set in the middle of the room it was allowed rather than over the
    /// figure it labels — a whole column of a form quietly sliding away from
    /// the numbers it belongs to.
    /// Whether to set this block as a heading — bold, and in a size of its
    /// own rather than the body's.
    ///
    /// A heading has its lines to itself. What a block *is* gets decided from
    /// the page — its box, how short it is, whether it ends in a stop — and on
    /// a form that is right often enough to be worth having and wrong in one
    /// particular way: a one-word cell measured a little taller than the row
    /// above it is a heading by every one of those signals. Set as one, it
    /// comes out bold and larger in the middle of a table, which is the same
    /// page-level nonsense as a run of type in four sizes. Whatever else it
    /// may be, it is not a heading if the rest of its row is printed beside
    /// it.
    static func isHeading(
        _ block: TranslatedBlock,
        among neighbours: [TranslatedBlock],
        in box: CGRect
    ) -> Bool {
        block.source.kind == .heading
            && !sharesLines(block, among: neighbours, in: box)
    }

    /// Whether anything else on the page is printed on this block's lines.
    static func sharesLines(
        _ block: TranslatedBlock,
        among neighbours: [TranslatedBlock],
        in box: CGRect
    ) -> Bool {
        let measured = rect(for: block.source.box, in: box)
        return neighbours.contains { other in
            guard other.id != block.id else { return false }
            let rect = rect(for: other.source.box, in: box)
            return rect.minY < measured.maxY && rect.maxY > measured.minY
        }
    }

    static func isCentred(
        _ block: TranslatedBlock,
        among neighbours: [TranslatedBlock],
        in box: CGRect
    ) -> Bool {
        guard !sharesLines(block, among: neighbours, in: box) else {
            return false
        }
        let measured = rect(for: block.source.box, in: box)

        let measure = measure(of: neighbours, in: box)
        let width = measure.right - measure.left
        guard width > 0 else { return false }
        let centre = (measure.left + measure.right) / 2
        return abs(measured.midX - centre) < width * 0.06
            && measured.width < width * 0.8
    }


    /// Normalized, origin top left — to PDF points, origin bottom left.
    public static func rect(for block: BlockBox, in box: CGRect) -> CGRect {
        CGRect(
            x: box.minX + CGFloat(block.x) * box.width,
            y: box.minY + CGFloat(1 - block.maxY) * box.height,
            width: CGFloat(block.width) * box.width,
            height: CGFloat(block.height) * box.height
        )
    }

    /// Normalized to pixels in the page image, whose origin is at the top
    /// left — so, unlike the PDF rect, no flip.
    public static func pixelRect(for block: BlockBox, in page: PageImage) -> CGRect {
        CGRect(
            x: CGFloat(block.x) * CGFloat(page.image.width),
            y: CGFloat(block.y) * CGFloat(page.image.height),
            width: CGFloat(block.width) * CGFloat(page.image.width),
            height: CGFloat(block.height) * CGFloat(page.image.height)
        )
    }
}
