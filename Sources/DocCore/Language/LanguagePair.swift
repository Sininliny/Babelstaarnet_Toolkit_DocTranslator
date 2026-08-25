import Foundation

/// What the pipeline needs to know about the language on the page.
///
/// Written down as data for the same reason the parent project learned to:
/// the alternative is Simplified Chinese spreading into the OCR, the block
/// assembly, the integrity checks, and the prompts, after which adding
/// Japanese means editing all four. Everything here is a fact about a script
/// or a writing convention. Nothing here is a *routing* decision — which
/// reader runs first, and what happens when they disagree, belongs to the
/// pipeline and is not a per-language knob.
public struct SourceLanguage: Sendable {
    /// BCP 47, and what Vision is asked for.
    public let identifier: String
    public let englishName: String
    /// The language's name for itself, shown in the interface beside the
    /// English one.
    public let endonym: String
    /// Passed to Vision, most specific first.
    public let visionRecognitionLanguages: [String]
    /// The characters that make this script itself. Used to tell an empty
    /// reading from a failed one, and to catch source text left untranslated
    /// in the English.
    public let scriptCharacters: CharacterSet
    /// Whether words are separated by spaces. False for Chinese, and it
    /// changes what a stray space in an OCR reading means.
    public let isSpaceSeparated: Bool
    /// Where a sentence stops, and everything the boundary algorithm needs to
    /// tell a stop from a decimal point, an ordinal or an abbreviation.
    public let sentenceRules: SentenceBoundaryRules
    /// Roughly how many target characters one source character becomes. A
    /// hanzi carries about as much as five or six English letters, so a
    /// translation far off this ratio is either truncated or looping.
    public let expansionRatio: ClosedRange<Double>
    /// How to name the language to a model.
    public let promptName: String
    /// How this language writes a number in words, when it does.
    ///
    /// Needed because the integrity checks compare figures, and a language
    /// that writes its dates as 二〇二四年三月二十日 has no digits in them at
    /// all — so a correct translation reading "20 March 2024" looks like
    /// three numbers invented out of nothing. Without this the check fires on
    /// almost every dated document, and a check that cries wolf on every page
    /// is one people learn to scroll past.
    ///
    /// Returns every form worth looking for; the caller only needs one of
    /// them to appear.
    public let writtenNumberForms: @Sendable (String) -> [String]
    /// Pack-supplied cleanup of one reader's raw text: the spaces Vision
    /// inserts between glyphs, the half-width punctuation a model
    /// substitutes, and anything else that is noise in this script but
    /// meaningful in another.
    public let normalizeReading: @Sendable (String) -> String

    public init(
        identifier: String,
        englishName: String,
        endonym: String,
        visionRecognitionLanguages: [String],
        scriptCharacters: CharacterSet,
        isSpaceSeparated: Bool,
        sentenceRules: SentenceBoundaryRules,
        expansionRatio: ClosedRange<Double>,
        promptName: String,
        writtenNumberForms: @escaping @Sendable (String) -> [String] = { _ in [] },
        normalizeReading: @escaping @Sendable (String) -> String = { $0 }
    ) {
        self.identifier = identifier
        self.englishName = englishName
        self.endonym = endonym
        self.visionRecognitionLanguages = visionRecognitionLanguages
        self.scriptCharacters = scriptCharacters
        self.isSpaceSeparated = isSpaceSeparated
        self.sentenceRules = sentenceRules
        self.expansionRatio = expansionRatio
        self.promptName = promptName
        self.writtenNumberForms = writtenNumberForms
        self.normalizeReading = normalizeReading
    }

    /// The characters that end a sentence, for the callers that only need to
    /// ask whether a line stops.
    public var sentenceTerminators: Set<Character> { sentenceRules.stops }

    /// How much of a string is this script, which is how the app tells "this
    /// page is in the language I was set up for" from "this page is not".
    public func scriptShare(of text: String) -> Double {
        let letters = text.unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0)
                && !CharacterSet.punctuationCharacters.contains($0)
        }
        guard !letters.isEmpty else { return 0 }
        let inScript = letters.filter { scriptCharacters.contains($0) }
        return Double(inScript.count) / Double(letters.count)
    }
}

/// What the pipeline needs to know about the language being written.
public struct TargetLanguage: Sendable {
    public let identifier: String
    public let englishName: String
    public let promptName: String
    public let isSpaceSeparated: Bool
    /// House style handed to the translating model. Kept with the language
    /// because "sentence case headings" is a convention of written English,
    /// not of translation in general.
    public let styleGuidance: [String]

    public init(
        identifier: String,
        englishName: String,
        promptName: String,
        isSpaceSeparated: Bool = true,
        styleGuidance: [String]
    ) {
        self.identifier = identifier
        self.englishName = englishName
        self.promptName = promptName
        self.isSpaceSeparated = isSpaceSeparated
        self.styleGuidance = styleGuidance
    }

    public static let english = TargetLanguage(
        identifier: "en",
        englishName: "English",
        promptName: "English",
        styleGuidance: [
            "Translate the meaning, not the word order.",
            "Keep numbers, dates, units, and proper nouns exactly as they are.",
            "Keep the register of the original: a notice stays a notice, a "
                + "contract clause stays a contract clause.",
            "Do not add anything the source does not say, and do not explain "
                + "or summarize."
        ]
    )
}

/// The direction of travel, chosen once at the composition root.
public struct LanguagePair: Sendable {
    public let source: SourceLanguage
    public let target: TargetLanguage

    public init(source: SourceLanguage, target: TargetLanguage) {
        self.source = source
        self.target = target
    }

    public var displayName: String {
        "\(source.englishName) → \(target.englishName)"
    }
}
