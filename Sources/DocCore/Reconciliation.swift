import Foundation

/// How a block's text was settled when the readers did not simply agree.
public enum Settlement: Sendable, Equatable {
    /// Every reader produced the same text, character for character.
    case unanimous
    /// Only one reader produced anything here.
    case single(PageReader)
    /// The PDF carried its own text, so nothing needed deciding.
    case textLayer
    /// The readers disagreed and a model was asked to choose, with both
    /// candidates in front of it.
    case adjudicated(chose: PageReader, because: String)
    /// The readers disagreed, the adjudicator was unavailable, and the
    /// higher-confidence reading was kept.
    case defaulted(to: PageReader, because: String)

    public var neededAModel: Bool {
        if case .adjudicated = self { return true }
        return false
    }

    public var summary: String {
        switch self {
        case .unanimous:
            return "Both readers agreed"
        case .single(let reader):
            return "Only \(reader.displayName) read this"
        case .textLayer:
            return "Taken from the PDF's own text"
        case .adjudicated(let reader, let because):
            return "Settled on \(reader.displayName): \(because)"
        case .defaulted(let reader, let because):
            return "Kept \(reader.displayName): \(because)"
        }
    }
}

/// A block after the readers have been compared: one text to translate, plus
/// everything needed to show the reader why it says what it says.
public struct ReconciledBlock: Sendable, Identifiable {
    public let id: UUID
    public let pageIndex: Int
    public let order: Int
    public let box: BlockBox
    public let kind: BlockKind
    /// How many printed lines the block occupied. Kept because it is the only
    /// record of how large the original type was: a box three lines tall says
    /// nothing about type size until you know it held three lines.
    public let lineCount: Int
    /// The text the translator will be given.
    public let text: String
    /// What each reader saw, kept even when they agreed — an agreement is
    /// only evidence if you can see what agreed.
    public let candidates: [PageReader: String]
    /// 1 when the readers matched exactly, 0 when they shared nothing, and
    /// `nil` when there was nothing to compare — one reader, or a reader that
    /// did not produce this block at all. Optional rather than zero because
    /// "the readers disagreed completely" and "nobody checked" call for
    /// different things from the person reading the result, and a single
    /// number cannot say both.
    public let agreement: Double?
    public let settlement: Settlement

    public init(
        id: UUID = UUID(),
        pageIndex: Int,
        order: Int,
        box: BlockBox,
        kind: BlockKind,
        lineCount: Int = 1,
        text: String,
        candidates: [PageReader: String],
        agreement: Double?,
        settlement: Settlement
    ) {
        self.id = id
        self.pageIndex = pageIndex
        self.order = order
        self.box = box
        self.kind = kind
        self.lineCount = max(1, lineCount)
        self.text = text
        self.candidates = candidates
        self.agreement = agreement
        self.settlement = settlement
    }

    public var wasContested: Bool {
        guard let agreement else { return false }
        return agreement < 1
    }

    /// Whether more than one reader actually looked at this block.
    public var wasDoubleChecked: Bool { agreement != nil }
}

/// How much the app is willing to stand behind a block, and why.
///
/// A single number would be worse than useless here: the reader has no way to
/// act on 0.62. The reasons are what they act on, so they are carried with it
/// and shown next to it.
public struct Confidence: Sendable, Equatable {
    public enum Band: String, Sendable, Comparable {
        case high
        case check
        case low

        public static func < (lhs: Band, rhs: Band) -> Bool {
            let order: [Band] = [.low, .check, .high]
            return order.firstIndex(of: lhs)! < order.firstIndex(of: rhs)!
        }

        public var label: String {
            switch self {
            case .high: return "Agreed"
            case .check: return "Worth a look"
            case .low: return "Needs a human"
            }
        }
    }

    public let score: Double
    public let reasons: [String]

    public init(score: Double, reasons: [String] = []) {
        self.score = min(1, max(0, score))
        self.reasons = reasons
    }

    public var band: Band {
        if score >= 0.85 { return .high }
        if score >= 0.6 { return .check }
        return .low
    }

    public static let unread = Confidence(
        score: 0,
        reasons: ["Nothing was read here"]
    )
}

/// A block, translated and reviewed.
public struct TranslatedBlock: Sendable, Identifiable {
    public var id: UUID { source.id }
    public let source: ReconciledBlock
    /// The translator's output.
    public let firstDraft: String
    /// The reviewer's revision, when it made one. `text` prefers this.
    public let revision: String?
    public let findings: [IntegrityFinding]
    public let confidence: Confidence

    public init(
        source: ReconciledBlock,
        firstDraft: String,
        revision: String? = nil,
        findings: [IntegrityFinding] = [],
        confidence: Confidence
    ) {
        self.source = source
        self.firstDraft = firstDraft
        self.revision = revision
        self.findings = findings
        self.confidence = confidence
    }

    /// What the export and the interface show.
    public var text: String { revision ?? firstDraft }

    public var wasRevised: Bool {
        guard let revision else { return false }
        return revision != firstDraft
    }
}

public struct TranslatedPage: Sendable, Identifiable {
    public var id: Int { index }
    public let index: Int
    public let blocks: [TranslatedBlock]

    public init(index: Int, blocks: [TranslatedBlock]) {
        self.index = index
        self.blocks = blocks
    }
}

/// Which engines produced a document, recorded so an export can say what read
/// it. A translation with no provenance is a claim; with it, it is a result.
public struct EngineRecord: Sendable, Equatable {
    public let readers: [String]
    public let adjudicator: String?
    public let translator: String?
    public let reviewer: String?

    public init(
        readers: [String],
        adjudicator: String?,
        translator: String?,
        reviewer: String?
    ) {
        self.readers = readers
        self.adjudicator = adjudicator
        self.translator = translator
        self.reviewer = reviewer
    }
}

public struct TranslatedDocument: Sendable, Identifiable {
    public let id: UUID
    public let source: DocumentSource
    public let languages: LanguagePair
    public let pages: [TranslatedPage]
    public let engines: EngineRecord
    public let finishedAt: Date

    public init(
        id: UUID = UUID(),
        source: DocumentSource,
        languages: LanguagePair,
        pages: [TranslatedPage],
        engines: EngineRecord,
        finishedAt: Date = Date()
    ) {
        self.id = id
        self.source = source
        self.languages = languages
        self.pages = pages
        self.engines = engines
        self.finishedAt = finishedAt
    }

    public var blocks: [TranslatedBlock] { pages.flatMap(\.blocks) }

    /// The blocks a person should look at before trusting the document, worst
    /// first. This is the app's actual output as much as the English is.
    public var needingAttention: [TranslatedBlock] {
        blocks
            .filter { $0.confidence.band != .high }
            .sorted { $0.confidence.score < $1.confidence.score }
    }
}
