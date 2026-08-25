import DocCore
import Foundation

/// Simplified Chinese, as data.
///
/// Nothing in the pipeline imports this target. It is handed to the modules as
/// a `SourceLanguage` value at the composition root, which is the only place
/// in the app that names a language at all.
public enum SimplifiedChinese {
    /// The blocks of Unicode a Chinese page is actually made of: the unified
    /// ideographs and their first extension, the compatibility block, the
    /// radicals a few documents use, and the full-width punctuation that
    /// belongs to the writing system rather than to the characters.
    ///
    /// Bopomofo and kana are deliberately absent. A page of kana is a
    /// Japanese page, and the app should say so rather than translate it as
    /// though the pack applied.
    public static let scriptCharacters: CharacterSet = {
        var set = CharacterSet()
        set.insert(charactersIn: "\u{4E00}"..."\u{9FFF}")   // CJK Unified
        set.insert(charactersIn: "\u{3400}"..."\u{4DBF}")   // Extension A
        set.insert(charactersIn: "\u{F900}"..."\u{FAFF}")   // Compatibility
        set.insert(charactersIn: "\u{2E80}"..."\u{2EFF}")   // Radicals
        set.insert(charactersIn: "\u{3000}"..."\u{303F}")   // CJK punctuation
        set.insert(charactersIn: "\u{FF00}"..."\u{FFEF}")   // Full-width forms
        return set
    }()

    /// Where a Chinese sentence stops.
    ///
    /// Three of these rules are exactly the ones the boundary algorithm was
    /// built to be told rather than to assume:
    ///
    /// - **A sentence does not open with a capital.** There are no capitals.
    ///   This removes the algorithm's strongest signal, so the declaration
    ///   matters: left at its default it would read every period followed by
    ///   a Chinese character as a stop inside a token.
    /// - **A lone letter before a period is not an initial**, because a lone
    ///   Latin letter in Chinese text is more often a label — 甲 A、乙 B — than
    ///   somebody's name.
    /// - **The full-width stops stand alone.** 。 is followed immediately by
    ///   the next sentence; a space there would be a typesetting error. The
    ///   ASCII period keeps the whitespace requirement, because in Chinese
    ///   text it is nearly always a decimal point or part of a URL.
    public static let sentenceRules = SentenceBoundaryRules(
        // The Latin abbreviations that turn up inside Chinese documents,
        // mostly in company names and addresses.
        abbreviations: ["co", "ltd", "no", "inc", "vs", "etc"],
        opensWithCapital: false,
        singleLetterIsInitial: false,
        stops: ["。", "！", "？", "；", "…", ".", "!", "?"],
        standAloneStops: ["。", "！", "？", "；", "…"],
        closers: ["”", "’", "」", "』", "）", "】", "》", "\"", "'", ")", "]"],
        openers: ["“", "‘", "「", "『", "（", "【", "《", "\"", "'", "(", "["]
    )

    public static let language = SourceLanguage(
        identifier: "zh-Hans",
        englishName: "Simplified Chinese",
        endonym: "简体中文",
        // Vision recognizes Chinese only at its accurate level, which is the
        // level this app uses everywhere. `zh-Hant` follows `zh-Hans` because
        // simplified text is the target and traditional characters appear in
        // it — in names, in quotations, and in documents that were never
        // fully converted — so the recognizer should not be forbidden from
        // returning one.
        visionRecognitionLanguages: ["zh-Hans", "zh-Hant", "en-US"],
        scriptCharacters: scriptCharacters,
        isSpaceSeparated: false,
        sentenceRules: sentenceRules,
        // One hanzi carries roughly a short English word. Measured loosely
        // and deliberately wide: this band exists to catch a paragraph that
        // came back as one line or as three pages, not to grade prose.
        expansionRatio: 0.8...4.5,
        promptName: "Simplified Chinese",
        normalizeReading: normalize(_:)
    )

    public static let toEnglish = LanguagePair(
        source: language,
        target: .english
    )

    /// What a reader's raw text needs before it can be compared with another
    /// reader's.
    ///
    /// The spaces are the important one. Vision returns Chinese with spaces
    /// scattered between glyphs — sometimes every character, sometimes none,
    /// and differently on two renders of the same page. A vision model
    /// returns none. Left alone, that difference alone makes two identical
    /// readings look like a 40% disagreement, and every block on every page
    /// would go to the adjudicator for nothing.
    ///
    /// A space between two Chinese characters is removed. A space beside a
    /// Latin letter or a digit is kept, because there it is a real word
    /// boundary in text that really is spaced.
    @Sendable
    public static func normalize(_ text: String) -> String {
        var output = ""
        output.reserveCapacity(text.count)
        let characters = Array(text)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == " " || character == "\u{3000}" {
                let previous = output.last
                var lookahead = index
                while lookahead < characters.count,
                      characters[lookahead] == " "
                        || characters[lookahead] == "\u{3000}" {
                    lookahead += 1
                }
                let next = lookahead < characters.count
                    ? characters[lookahead]
                    : nil
                if let previous, let next,
                   isChinese(previous), isChinese(next) {
                    index = lookahead
                    continue
                }
                if previous != nil, next != nil {
                    output.append(" ")
                }
                index = lookahead
                continue
            }
            output.append(character)
            index += 1
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isChinese(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy(scriptCharacters.contains)
    }
}
