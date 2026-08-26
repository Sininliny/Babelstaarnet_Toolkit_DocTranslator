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
        contextCues: contextCues,
        romanization: pinyin,
        writtenNumberForms: writtenForms(of:),
        normalizeReading: normalize(_:)
    )

    public static let toEnglish = LanguagePair(
        source: language,
        target: .english
    )

    /// What a Chinese block uses to point at something that is not in it.
    ///
    /// The list is deliberately made of two-character expressions rather than
    /// the obvious single characters. 本 and 其 are in a very large share of
    /// official Chinese — 本院, 本通知, 其他 — so a rule that fired on them
    /// would widen the context for nearly every block on nearly every page,
    /// which costs exactly as much as never adapting at all and produces the
    /// failure the adaptation exists to avoid. 上述 and 前款 are unambiguous:
    /// each of them says, in as many words, that the thing being referred to
    /// is somewhere else.
    ///
    /// Twenty characters is where a Chinese block stops being a sentence.
    /// A hanzi carries about as much as a short English word, so twenty of
    /// them is a line of prose; below that, on the documents this app is
    /// pointed at, it is a heading, a table cell, a party's name, or a date.
    public static let contextCues = ContextCues(
        referring: [
            "该", "上述", "前述", "该等", "前款", "本款", "本条", "本项",
            "同上", "如前", "上款", "前项", "其中", "此项", "上款所述"
        ],
        continuing: [
            "但", "但是", "并", "并且", "而且", "因此", "所以", "否则",
            "此外", "同时", "其次", "另外", "如前所述", "为此", "据此"
        ],
        selfContainedLength: 20,
        // 应该 and 不该 are "ought to" and "ought not to". Both contain 该,
        // which is the strongest referring cue in the list, and both are in
        // roughly every second sentence of an official Chinese document.
        falseFriends: ["应该", "不该", "活该", "该死"]
    )

    /// The ideographs alone — the characters that have a Pinyin reading.
    ///
    /// Narrower than `scriptCharacters`, which also carries 。、《》 and the
    /// full-width forms, because those are punctuation: they have no reading,
    /// and a run that includes one cannot be spelled out character by
    /// character.
    public static let ideographs: CharacterSet = {
        var set = CharacterSet()
        set.insert(charactersIn: "\u{4E00}"..."\u{9FFF}")   // CJK Unified
        set.insert(charactersIn: "\u{3400}"..."\u{4DBF}")   // Extension A
        set.insert(charactersIn: "\u{F900}"..."\u{FAFF}")   // Compatibility
        return set
    }()

    /// Chinese spelled out in Latin letters, which is what a translation is
    /// not.
    ///
    /// This is the pack's half of the app's answer to the worst thing a
    /// translator can do to a prescription. 布洛芬 is ibuprofen; a model that
    /// renders it character by character writes "Buluofen", which is not a
    /// word in any language and names no drug, and which arrives in an
    /// otherwise fluent English sentence where a reader who cannot read
    /// Chinese will take it for the name of their medicine. Nothing about
    /// the output looks wrong. So the app spells the source out itself and
    /// looks for the result in the English: if it is there, the model did the
    /// one thing it was told not to.
    ///
    /// Tone marks are stripped and the case is folded because the English is
    /// searched for a word, and no translation writes "Bùluòfēn".
    public static let pinyin = Romanization(
        name: "Pinyin",
        characters: ideographs,
        syllables: syllables(of:)
    )

    /// One syllable per character, or nothing.
    ///
    /// Whole runs are transliterated rather than single characters, because
    /// which reading a character takes depends on the ones beside it — 行 is
    /// xíng in 银行业 and háng in 银行 — and a per-character lookup would get
    /// the common cases wrong in both directions. The count is then checked
    /// against the run: a transform that returned some other number of
    /// syllables has not told the caller which character made which, and the
    /// caller has no use for an answer it cannot align.
    @Sendable
    public static func syllables(of text: String) -> [String] {
        let characters = Array(text)
        guard !characters.isEmpty,
              characters.allSatisfy({
                  $0.unicodeScalars.allSatisfy(ideographs.contains)
              })
        else { return [] }

        guard let latin = text.applyingTransform(.toLatin, reverse: false)
        else { return [] }
        let plain = latin.applyingTransform(.stripDiacritics, reverse: false)
            ?? latin
        let syllables = plain
            .lowercased()
            .split(whereSeparator: { $0 == " " || $0 == "'" })
            .map(String.init)
        guard syllables.count == characters.count else { return [] }
        return syllables
    }

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

    static let numerals: [Character] = [
        "〇", "一", "二", "三", "四", "五", "六", "七", "八", "九"
    ]

    /// The ways Chinese writes a number, so a translation that turned one
    /// into digits is not reported as having invented it.
    ///
    /// Two forms, because Chinese uses two. A year is written digit by digit
    /// — 二〇二四 — and a count is written positionally: 二十 for twenty,
    /// 十二 for twelve, 十 for ten. Above ninety-nine the positional form
    /// needs 百, 千 and 万 and the composition stops being worth writing out
    /// here; a document's large figures are nearly always printed as digits
    /// anyway, which is the case the check is really for.
    @Sendable
    public static func writtenForms(of digits: String) -> [String] {
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return [] }

        // 二〇二四: every digit spelled, in order.
        var perDigit = ""
        for character in digits {
            guard let value = character.wholeNumberValue,
                  value >= 0, value < numerals.count else { return [] }
            perDigit.append(numerals[value])
        }

        var forms = [perDigit]
        if let value = Int(digits), value > 0, value < 100 {
            forms.append(positional(value))
        }
        return forms
    }

    /// 1...99 in the ordinary counting form.
    static func positional(_ value: Int) -> String {
        if value < 10 { return String(numerals[value]) }
        let tens = value / 10
        let units = value % 10
        var form = ""
        if tens > 1 { form.append(numerals[tens]) }
        form.append("十")
        if units > 0 { form.append(numerals[units]) }
        return form
    }

    static func isChinese(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy(scriptCharacters.contains)
    }
}
