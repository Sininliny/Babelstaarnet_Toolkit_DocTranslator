import Foundation

/// What is printed around a block, as far as the pipeline can see it.
///
/// The unit of translation is the sentence, and that is not negotiable: it is
/// what a translator needs to see at once, what a confidence score is worth
/// attaching to, and small enough that a person checking a flagged block can
/// find it on the page. The cost of that unit is that a sentence arrives with
/// nothing around it, and some sentences do not mean anything on their own.
///
/// So the neighbourhood is collected here and spent selectively. See
/// `ContextNeed` for why "selectively" rather than "always".
public struct TranslationContext: Sendable, Equatable {
    /// The sentence before this one, as printed.
    public var previousSource: String?
    /// And what it was translated into. This is the half that keeps a
    /// recurring term rendered the same way twenty sentences apart without
    /// anyone having written the term down.
    public var previousTarget: String?
    /// The sentence after this one, as printed. Not translated yet — it has
    /// not been reached — so there is only a source half.
    public var nextSource: String?
    /// The heading this block sits under, carried across page breaks. A
    /// section heading governs the rows beneath it, and the last row of a
    /// table on page three is still under the heading on page two.
    public var sectionHeading: String?

    public init(
        previousSource: String? = nil,
        previousTarget: String? = nil,
        nextSource: String? = nil,
        sectionHeading: String? = nil
    ) {
        self.previousSource = previousSource
        self.previousTarget = previousTarget
        self.nextSource = nextSource
        self.sectionHeading = sectionHeading
    }

    public static let none = TranslationContext()

    public var isEmpty: Bool {
        previousSource == nil && previousTarget == nil
            && nextSource == nil && sectionHeading == nil
    }
}

/// Which parts of the neighbourhood this particular block is actually given.
///
/// The reason this is a decision rather than "all of it, every time" is that
/// context is neither free nor harmless.
///
/// It is not free because the model doing this work is running on the
/// reader's own laptop. Every character in front of the block is a character
/// the machine encodes before it writes a word of the translation, on every
/// block, on every page — and the app's own model reads a page in twenty
/// seconds, so a doubled prompt is felt rather than measured.
///
/// It is not harmless because a small model handed two sentences and asked
/// for one translation will sometimes translate both, or continue the
/// context instead of the block. That failure does not look like a failure:
/// it produces fluent English of a sentence that is on the page, in the wrong
/// place, and every mechanical check downstream passes it. Padding a
/// four-character heading with four hundred characters of surrounding prose
/// is the reliable way to provoke it.
///
/// So the floor is what the block always gets — the English of the line
/// before it, which is what stops a term drifting — and everything above the
/// floor has to be asked for by the block itself. A sentence that stands on
/// its own is translated on its own.
public struct ContextNeed: Sendable, Equatable {
    /// The previous sentence as printed. Withheld from a self-contained
    /// block, because the source half is the part a model mistakes for
    /// something to translate.
    public var previousSource: Bool
    /// The English of the previous sentence. The floor: given whenever there
    /// is one, because it is short, it is already in the target language, and
    /// it is what keeps 甲方 from becoming "the first party" on page seven.
    public var previousTarget: Bool
    /// The sentence after this one. What a heading means is decided by the
    /// section under it, not by the heading itself.
    public var following: Bool
    /// The heading this block sits under.
    public var heading: Bool
    /// Set when the block was translated a second time with nothing around
    /// it at all, because the first answer was the source copied back.
    ///
    /// Measured, not guessed. Put to a 3B five times over each of five blocks
    /// of a court notice: with no context, none of the twenty-five answers
    /// came back untranslated; with the line before it — in any wording, and
    /// whether the Chinese half was included or not — four or five did, always
    /// on the same block, a numbered item that is mostly figures. Something
    /// in front of a block that is nearly all digits is enough to tip a small
    /// model from translating into copying.
    ///
    /// The rule this licenses is narrow on purpose. Deciding in advance which
    /// blocks are "too numeric for context" would be fitting a rule to one
    /// measurement: the item that failed is 44% digits and the one below it,
    /// which never failed, is 38%. So nothing is decided in advance. The
    /// mechanical check already detects this exact failure, and detection is
    /// the trigger: a block that came back as its own source, and *was* given
    /// context, is translated once more without any. It costs a second call
    /// only where the first one demonstrably failed.
    public var retriedAlone: Bool
    /// Why, in words, so the side-by-side export can show what the translator
    /// was actually looking at. A confidence score the reader cannot account
    /// for is a number; this is a reason.
    public var reasons: [String]

    public init(
        previousSource: Bool = false,
        previousTarget: Bool = false,
        following: Bool = false,
        heading: Bool = false,
        retriedAlone: Bool = false,
        reasons: [String] = []
    ) {
        self.previousSource = previousSource
        self.previousTarget = previousTarget
        self.following = following
        self.heading = heading
        self.retriedAlone = retriedAlone
        self.reasons = reasons
    }

    /// What a block translated again on its own is left with: no context, and
    /// the note saying why.
    public static let alone = ContextNeed(
        retriedAlone: true,
        reasons: [
            "translated again with nothing around it, because the first "
                + "answer was the source text copied back"
        ]
    )

    public static let none = ContextNeed()

    public var isEmpty: Bool {
        !previousSource && !previousTarget && !following && !heading
    }

    /// Whether anything beyond the floor was asked for, which is the thing
    /// worth showing a reader.
    public var wasWidened: Bool { previousSource || following || heading }
}

/// Deciding how much of the page around a block the translator is shown.
///
/// The signals are all properties of the block itself, and they are the three
/// ways a sentence fails to stand alone:
///
/// - **It is too short to carry its own context.** A heading, a table cell, a
///   one-line label. 执行 is "enforcement" in a court notice and "execution"
///   in a technical manual, and the block itself contains nothing that
///   decides which.
/// - **It points at something outside itself.** 该方, 上述, 前款 — a
///   reference whose referent is in the sentence before it, and which becomes
///   "the said party" or worse when the translator cannot see what is being
///   referred to.
/// - **It continues something.** A block beginning 但是 or 因此, or one whose
///   predecessor did not end at a sentence stop, is half of a thought.
///
/// What each signal buys is different, and that matters more than the signals
/// themselves. A reference backwards is answered by the sentence *before*; a
/// heading is answered by the section *after* it; an item in a list is
/// answered by the heading above the list, which may be on a different page.
/// Handing every block all three would cost the same as handing it none and
/// would be worse than either.
public enum AdaptiveContext {

    public static func need(
        for text: String,
        kind: BlockKind,
        available context: TranslationContext,
        language: SourceLanguage
    ) -> ContextNeed {
        guard kind.isTranslatable, !context.isEmpty else { return .none }

        let cues = language.contextCues
        let scrubbed = cues.withoutFalseFriends(text)
        var need = ContextNeed()
        var reasons: [String] = []

        // The floor. Short, already in the target language, and the one piece
        // of context with a measured job: consistency of naming.
        if context.previousTarget != nil {
            need.previousTarget = true
            reasons.append("the English of the line before it")
        }

        let isFragment = text.count < cues.selfContainedLength
        let refersOutward = cues.referring.contains { scrubbed.contains($0) }
        let continues = cues.continuing.contains { scrubbed.hasPrefix($0) }
            || !endsAtAStop(context.previousSource, language: language)

        if isFragment, context.previousSource != nil {
            need.previousSource = true
            reasons.append("it is too short to say what it is about")
        }
        if refersOutward, context.previousSource != nil {
            need.previousSource = true
            reasons.append("it refers to something outside itself")
        }
        if continues, context.previousSource != nil {
            need.previousSource = true
            reasons.append("it continues the sentence before it")
        }

        // A heading is named by what it introduces. This is the one case
        // where looking forward is worth more than looking back, and it is
        // also the case where a wrong choice is repeated in every reference
        // to that section afterwards.
        if context.nextSource != nil, kind == .heading || isFragment {
            need.following = true
            reasons.append(
                kind == .heading
                    ? "what the section under it says"
                    : "the line after it"
            )
        }

        // An item under a stem. On a form this is most of the page: a cell
        // reading 3 means nothing, and the column heading above it is the
        // whole content of the block.
        if context.sectionHeading != nil,
           kind == .listItem || kind == .tableRow || isFragment
            || refersOutward {
            need.heading = true
            reasons.append("the heading it sits under")
        }

        need.reasons = reasons
        return need
    }

    /// Whether what came before finished. `nil` — nothing came before — is
    /// treated as finished: the first block of a document does not continue
    /// anything.
    static func endsAtAStop(
        _ text: String?,
        language: SourceLanguage
    ) -> Bool {
        guard let text else { return true }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return true }
        if language.sentenceTerminators.contains(last) { return true }
        // A closing quote or bracket after the stop still ends the sentence.
        if language.sentenceRules.closers.contains(last) {
            let withoutCloser = trimmed.dropLast()
            return withoutCloser.last.map {
                language.sentenceTerminators.contains($0)
            } ?? false
        }
        return false
    }
}

/// The words a language uses to point outside a sentence, and how short a
/// block has to be before it carries no context of its own.
///
/// In the language pack because they are facts about a writing system, not
/// tuning: 上述 is Chinese for "the above", and no amount of configuration
/// makes it English. A pack that says nothing here gets a pipeline that never
/// widens the context, which is the behaviour the app had before this
/// existed.
public struct ContextCues: Sendable {
    /// Expressions whose meaning is somewhere else on the page.
    public let referring: [String]
    /// Expressions that only make sense as the continuation of something,
    /// matched at the start of a block.
    public let continuing: [String]
    /// Below this many characters, a block is a heading, a cell, or a label
    /// rather than a sentence.
    public let selfContainedLength: Int
    /// Words that contain a cue and are not one.
    ///
    /// Needed because the cues are matched as substrings, and in a language
    /// written without spaces there is nothing else to match on. 应该 means
    /// "ought to" and contains 该; without this list, every obligation in the
    /// document reads as a reference to something outside itself, which on a
    /// court notice is every sentence — and a rule that fires on everything
    /// is the rule that was not written.
    public let falseFriends: [String]

    public init(
        referring: [String] = [],
        continuing: [String] = [],
        selfContainedLength: Int = 0,
        falseFriends: [String] = []
    ) {
        self.referring = referring
        self.continuing = continuing
        self.selfContainedLength = selfContainedLength
        self.falseFriends = falseFriends
    }

    /// The text with the false friends taken out, so a cue found in what is
    /// left is really a cue. Taken out rather than replaced, because the
    /// remaining characters are only ever searched, never read.
    public func withoutFalseFriends(_ text: String) -> String {
        guard !falseFriends.isEmpty else { return text }
        var scrubbed = text
        for word in falseFriends {
            scrubbed = scrubbed.replacingOccurrences(of: word, with: "\u{FFFD}")
        }
        return scrubbed
    }

    public static let none = ContextCues()
}
