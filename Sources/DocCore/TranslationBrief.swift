import Foundation

/// A term the reader wants handled a particular way.
public struct GlossaryTerm: Sendable, Identifiable, Equatable, Codable {
    public enum Handling: Sendable, Equatable, Codable {
        /// Leave it exactly as it appears in the source — a name, a brand, a
        /// case number, a chemical formula.
        case keepAsWritten
        /// Always render it this way.
        case render(String)
    }

    public let id: UUID
    /// As it appears in the source.
    public let term: String
    public let handling: Handling
    /// Why, in the reader's own words. Shown back to them, and given to the
    /// model, because "the Company" instead of "the company" is a decision
    /// with a reason behind it that the model can apply to near misses.
    public let note: String?

    public init(
        id: UUID = UUID(),
        term: String,
        handling: Handling,
        note: String? = nil
    ) {
        self.id = id
        self.term = term
        self.handling = handling
        self.note = note
    }

    /// What the translation must contain if the source block contains the
    /// term. This is what makes the instruction checkable rather than merely
    /// requested.
    public var requiredInTranslation: String {
        switch handling {
        case .keepAsWritten: return term
        case .render(let rendering): return rendering
        }
    }

    public var instruction: String {
        let base: String
        switch handling {
        case .keepAsWritten:
            base = "Leave “\(term)” exactly as it is written in the source; "
                + "do not translate or transliterate it."
        case .render(let rendering):
            base = "Always translate “\(term)” as “\(rendering)”."
        }
        guard let note, !note.isEmpty else { return base }
        return base + " (\(note))"
    }
}

/// What the reader wants from this translation, beyond "translate it".
///
/// A translation is not one job with one right answer. Whether 王小明 becomes
/// "Wang Xiaoming" or stays 王小明, whether 公司 is "the company" or "the
/// Company", whether a term of art is rendered in the reader's field's
/// vocabulary or in general English — these are the reader's decisions, and a
/// translator that makes them silently is guessing at something it was never
/// told.
///
/// The brief is carried through the whole pipeline: the translator works to
/// it, the reviewer checks against it, and `TextIntegrity` enforces the parts
/// of it that can be enforced mechanically.
public struct TranslationBrief: Sendable, Equatable, Codable {
    /// The reader's own words. Free text, because the useful instructions are
    /// the ones nobody anticipated: "this is a court filing, keep it formal",
    /// "this is my grandmother's letter, keep it warm".
    public var instructions: [String]
    public var glossary: [GlossaryTerm]
    /// Questions the app asked about the document and the answers it was
    /// given. Kept apart from `instructions` so the interface can show what
    /// was asked, and so re-running a document does not ask again.
    public var settledQuestions: [SettledQuestion]

    public init(
        instructions: [String] = [],
        glossary: [GlossaryTerm] = [],
        settledQuestions: [SettledQuestion] = []
    ) {
        self.instructions = instructions
        self.glossary = glossary
        self.settledQuestions = settledQuestions
    }

    public static let none = TranslationBrief()

    public var isEmpty: Bool {
        instructions.isEmpty && glossary.isEmpty && settledQuestions.isEmpty
    }

    /// Everything the brief says, as lines for a model. Ordered with the
    /// reader's own instructions last, so that where the reader and an
    /// answered question disagree, the reader wins.
    public var guidanceLines: [String] {
        settledQuestions.map(\.guidance)
            + glossary.map(\.instruction)
            + instructions
    }

    /// The terms that apply to a given source text, which is all the
    /// translator needs to be told about for one block.
    public func glossary(applyingTo text: String) -> [GlossaryTerm] {
        glossary.filter { text.contains($0.term) }
    }
}

/// A question the app asked about the document, and what the reader said.
public struct SettledQuestion: Sendable, Equatable, Codable, Identifiable {
    public let id: UUID
    public let question: String
    public let answer: String
    /// The instruction the answer becomes. Separate from the answer itself
    /// because "It is a medical record" is what the reader clicked and
    /// "Translate clinical terms with their standard English equivalents" is
    /// what the translator needs to hear.
    public let guidance: String

    public init(
        id: UUID = UUID(),
        question: String,
        answer: String,
        guidance: String
    ) {
        self.id = id
        self.question = question
        self.answer = answer
        self.guidance = guidance
    }
}

/// Something about the document the app cannot settle on its own.
///
/// Raised *before* the translation rather than reported after it. A
/// translator that guesses at the document's field, its formality, or who
/// "对方" refers to will produce a fluent translation built on that guess,
/// and the reader has no way to see the guess in the output — it reads
/// exactly like a translation that knew. Asking costs one dialog; not asking
/// costs a plausible wrong document.
public struct ClarificationQuestion: Sendable, Identifiable, Equatable {
    public let id: UUID
    public let question: String
    public let options: [ClarificationOption]
    /// The text that raised it, so the reader can see what the app is looking
    /// at rather than answering in the abstract.
    public let evidence: String?

    public init(
        id: UUID = UUID(),
        question: String,
        options: [ClarificationOption],
        evidence: String? = nil
    ) {
        self.id = id
        self.question = question
        self.options = options
        self.evidence = evidence
    }
}

public struct ClarificationOption: Sendable, Identifiable, Equatable {
    public let id: UUID
    /// What the reader sees on the button.
    public let label: String
    /// What choosing it tells the translator.
    public let guidance: String

    public init(id: UUID = UUID(), label: String, guidance: String) {
        self.id = id
        self.label = label
        self.guidance = guidance
    }

    /// Always offered, always last. A reader who does not know the answer
    /// must be able to say so — an app that forces a choice between two
    /// guesses has converted "we are unsure" into "the user decided", which
    /// is worse than not asking.
    public static let unsure = ClarificationOption(
        label: "I'm not sure",
        guidance: "The reader does not know. Translate this literally and "
            + "flag anything that depends on the answer."
    )
}
