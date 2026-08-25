import DocCore
import Foundation

/// Enough of the document to say what the document is.
///
/// The profile that every sentence is translated against is only as good as
/// what it was built from, and the opening page is a bad sample of a long
/// document. A contract states its parties on page one and defines its terms
/// on page three. A judgment opens with a case number and says what was
/// decided at the end. A report's first page is a cover sheet. Profile from
/// the opening alone and the app has read the letterhead and called it a
/// reading.
///
/// So the survey spans the document, and what it costs depends on what the
/// document is:
///
/// - **A PDF that carries its own text** costs nothing at all. The text layer
///   is already there, for every page, and reading twelve pages of it is a
///   dictionary lookup.
/// - **A scan or a photograph** has to be recognized, so the survey is
///   rationed: the page the pipeline has already read, plus at most two more,
///   and only with a reader quick enough that the reader of the app does not
///   wait on it. Those two pages are then recognized a second time when the
///   pipeline reaches them properly. That is a second of Vision, paid once,
///   and it buys a profile that saw the end of the document — a cache to
///   avoid it would have to survive between two stages that otherwise share
///   nothing.
///
/// Neither path reads the whole of a long document, and neither claims to.
/// What both produce is a sample taken from across it rather than off the
/// front of it, which is the difference between knowing what kind of document
/// this is and knowing what its first paragraph looked like.
public struct DocumentSurvey: Sendable {
    /// How much text the profile is built from. Large enough to span a
    /// document, small enough that reading it is one model call rather than a
    /// second pass over the document.
    public static let sampleLimit = 4_000
    /// How much of that the opening may take. The opening is the most
    /// informative part of most documents and it must not be the only part.
    public static let openingLimit = 2_000
    /// Pages sampled when the text is already there for the taking.
    public static let freePageLimit = 12
    /// Pages sampled when each one has to be recognized first. Two, because
    /// the middle and the end of a document are where it stops being its own
    /// cover page, and because a third would be paid for in seconds the
    /// reader spends watching a progress bar.
    public static let recognizedPageLimit = 2

    private let provider: any PageProvider
    private let language: SourceLanguage
    /// The reader used for pages the document does not carry text for. Nil
    /// when no reader is quick enough to be worth it, in which case the
    /// survey covers whatever the text layer and the opening give it.
    private let reader: (any PageTranscriber)?

    public init(
        provider: any PageProvider,
        language: SourceLanguage,
        reader: (any PageTranscriber)? = nil
    ) {
        self.provider = provider
        self.language = language
        self.reader = reader
    }

    /// - Parameter blocks: the first page, already read and reconciled by the
    ///   pipeline. Passed in rather than read again: it is the best text the
    ///   app has of that page, and re-recognizing it would be paying twice
    ///   for a worse answer.
    public func sample(openingWith blocks: [ReconciledBlock]) async -> String {
        let opening = Self.text(of: blocks, limit: Self.openingLimit)
        var sample = opening.isEmpty ? "" : "[page 1]\n" + opening
        var budget = Self.sampleLimit - sample.count
        guard budget > 0, provider.source.pageCount > 1 else { return sample }

        // How many pages, and which, is decided by what a page costs here. A
        // document that carries its own text can be sampled widely: the text
        // is already in the file and reading twelve pages of it is a
        // dictionary lookup. One that has to be recognized gets two, and
        // they are chosen for spread rather than for convenience — two more
        // pages off the front of the document is the sample this whole stage
        // exists to stop relying on.
        var recognized = 0
        let carriesItsOwnText = provider.textLayer(
            at: provider.source.pageCount - 1,
            language: language
        ) != nil
        let pages = Self.surveyPages(
            of: provider.source.pageCount,
            limit: carriesItsOwnText || reader == nil
                ? Self.freePageLimit
                : Self.recognizedPageLimit
        )
        // Split what is left evenly, so one verbose page in the middle cannot
        // spend the budget the last page needed.
        let share = max(200, budget / max(1, pages.count))

        for index in pages {
            guard budget > 0 else { break }
            var page: String
            if let layer = provider.textLayer(at: index, language: language) {
                page = Self.text(of: layer.blocks, limit: min(share, budget))
            } else if let reader, recognized < Self.recognizedPageLimit {
                recognized += 1
                guard let image = try? provider.page(at: index),
                      let reading = try? await reader.transcribe(
                          image,
                          language: language
                      )
                else { continue }
                page = Self.text(of: reading.blocks, limit: min(share, budget))
            } else {
                continue
            }
            guard !page.isEmpty else { continue }
            // Marked with the page it came from, because it is an excerpt and
            // a model handed excerpts as continuous prose will explain the
            // jumps to itself.
            page = "\n\n[page \(index + 1)]\n" + page
            sample += page
            budget -= page.count
        }
        return sample
    }

    /// Which pages to look at, spread across the document and always ending
    /// on the last one. The end of a document is where its purpose tends to
    /// be stated — what was ordered, what was agreed, who signed it — and a
    /// sample that stops two thirds of the way through misses it.
    ///
    /// Spaced as though the opening, which the pipeline has already read,
    /// were the first sample. Two picks out of twenty pages are then page ten
    /// and page twenty, rather than pages two and twenty: the opening has
    /// already said whatever the front of the document has to say.
    public static func surveyPages(of pageCount: Int, limit: Int) -> [Int] {
        guard pageCount > 1, limit > 0 else { return [] }
        let rest = Array(1..<pageCount)
        guard rest.count > limit else { return rest }
        var picked: [Int] = []
        for step in 1...limit {
            let fraction = Double(step) / Double(limit)
            let index = Int((Double(rest.count - 1) * fraction).rounded())
            let page = rest[index]
            if picked.last != page { picked.append(page) }
        }
        return picked
    }

    static func text<Block: SurveyableBlock>(
        of blocks: [Block],
        limit: Int
    ) -> String {
        var text = ""
        for block in blocks where block.kind.isTranslatable {
            guard text.count < limit else { break }
            let room = limit - text.count
            text += block.text.count > room
                ? String(block.text.prefix(room))
                : block.text + "\n"
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// What the survey needs of a block, which is all that the two kinds of block
/// it draws from — reconciled and straight off a reader — have in common.
public protocol SurveyableBlock {
    var kind: BlockKind { get }
    var text: String { get }
}

extension ReconciledBlock: SurveyableBlock {}
extension SourceBlock: SurveyableBlock {}
