import Foundation

/// Something wrong with a translation, found without asking anyone.
public struct IntegrityFinding: Sendable, Identifiable, Equatable {
    public enum Severity: Int, Sendable, Comparable {
        case note = 0
        case caution = 1
        case blocking = 2

        public static func < (lhs: Severity, rhs: Severity) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    public enum Kind: String, Sendable, Equatable {
        case emptyTranslation
        case echoedSource
        case untranslatedScript
        case droppedNumber
        case inventedNumber
        case lengthOutOfRange
        case repeatedRun
        case leakedInstruction
        case briefIgnored
    }

    public let id: UUID
    public let kind: Kind
    public let severity: Severity
    public let message: String
    /// The exact text that triggered it, so the interface can point at it
    /// rather than describe it.
    public let evidence: String?

    public init(
        id: UUID = UUID(),
        kind: Kind,
        severity: Severity,
        message: String,
        evidence: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.severity = severity
        self.message = message
        self.evidence = evidence
    }
}

/// The checks that need no model.
///
/// A second model reviewing the first one is the interesting half of the
/// double-check and the unreliable half: it is another language model, with
/// the same blind spots, and it will approve a confident-sounding paragraph
/// that quietly dropped a figure. These checks are the other half. They are
/// mechanical, they are cheap enough to run on every block, and they catch the
/// specific failures that matter most in a document a person is going to act
/// on: a number that changed, a clause that vanished, a model that looped, a
/// paragraph handed back untranslated.
///
/// Everything here is deliberately about *form*, never meaning. Meaning is
/// what the reviewing model is for.
public enum TextIntegrity {
    public static func check(
        source: String,
        translation: String,
        language: SourceLanguage,
        target: TargetLanguage,
        brief: TranslationBrief = .none
    ) -> [IntegrityFinding] {
        var findings: [IntegrityFinding] = []
        let trimmedSource = source.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let trimmed = translation.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        guard !trimmedSource.isEmpty else { return [] }

        if trimmed.isEmpty {
            return [
                IntegrityFinding(
                    kind: .emptyTranslation,
                    severity: .blocking,
                    message: "Nothing came back for a block that has text."
                )
            ]
        }

        // Handed back unchanged. Common when a model decides the source is
        // already in the target language, and invisible in a bilingual view
        // where the two columns are meant to differ.
        if TextSimilarity.score(trimmedSource, trimmed) > 0.9 {
            findings.append(
                IntegrityFinding(
                    kind: .echoedSource,
                    severity: .blocking,
                    message: """
                        The \(target.englishName) is the same text as the \
                        \(language.englishName).
                        """,
                    evidence: String(trimmed.prefix(80))
                )
            )
        }

        // A term the reader asked to keep in the original is the reader's
        // decision, and it must not then be reported as untranslated text.
        // Removing it before measuring is the difference between an
        // instruction the app follows and an instruction it follows while
        // complaining.
        var measured = trimmed
        for term in brief.glossary where term.handling == .keepAsWritten {
            measured = measured.replacingOccurrences(of: term.term, with: "")
        }

        // Source script left in the output. A little is legitimate — a name
        // kept beside its transliteration — and a lot means a paragraph was
        // skipped.
        let share = language.scriptShare(of: measured)
        if share > 0.15 {
            findings.append(
                IntegrityFinding(
                    kind: .untranslatedScript,
                    severity: share > 0.4 ? .blocking : .caution,
                    message: """
                        \(Int(share * 100))% of this block is still \
                        \(language.englishName).
                        """,
                    evidence: firstRun(of: language.scriptCharacters, in: measured)
                )
            )
        }

        findings.append(
            contentsOf: numberFindings(source: trimmedSource, translation: trimmed)
        )

        // Length. The band is a property of the language pair, because how
        // much one source character carries is.
        let sourceLength = Double(countingLetters(trimmedSource))
        let targetLength = Double(countingLetters(trimmed))
        if sourceLength >= 8 {
            let ratio = targetLength / sourceLength
            if !language.expansionRatio.contains(ratio) {
                let tooShort = ratio < language.expansionRatio.lowerBound
                findings.append(
                    IntegrityFinding(
                        kind: .lengthOutOfRange,
                        severity: tooShort ? .caution : .note,
                        message: tooShort
                            ? "Much shorter than the source — something may "
                                + "have been left out."
                            : "Much longer than the source — something may "
                                + "have been added."
                    )
                )
            }
        }

        if let run = repeatedRun(in: trimmed) {
            findings.append(
                IntegrityFinding(
                    kind: .repeatedRun,
                    severity: .blocking,
                    message: "The same phrase repeats — the model looped.",
                    evidence: run
                )
            )
        }

        // What the reader asked for, checked rather than hoped for. A model
        // told to keep a name in the original will usually do it and will
        // sometimes translate it anyway, and the reader has no way to notice
        // in a language they cannot read — which is the entire situation
        // they are in.
        for term in brief.glossary(applyingTo: trimmedSource) {
            let required = term.requiredInTranslation
            guard !trimmed.contains(required) else { continue }
            findings.append(
                IntegrityFinding(
                    kind: .briefIgnored,
                    severity: .blocking,
                    message: "You asked for “\(term.term)” to be handled a "
                        + "particular way, and this block does not do it.",
                    evidence: required
                )
            )
        }

        if let leak = instructionLeak(in: trimmed) {
            findings.append(
                IntegrityFinding(
                    kind: .leakedInstruction,
                    severity: .caution,
                    message: "The model answered about the task instead of "
                        + "translating.",
                    evidence: leak
                )
            )
        }

        return findings
    }

    // MARK: - Numbers

    /// Digits are the part of a document a mistranslation does the most damage
    /// to and the part a fluent-sounding paragraph hides best. A dose, a
    /// deadline, a price, or a clause number that changed between the source
    /// and the English is worth stopping for.
    ///
    /// Compared as multisets of digit runs, with separators stripped, because
    /// `1,000` and `1000` are the same figure and `3.5` and `3,5` are not
    /// something this check is qualified to have an opinion about.
    static func numberFindings(
        source: String,
        translation: String
    ) -> [IntegrityFinding] {
        var findings: [IntegrityFinding] = []
        var inSource = numberRuns(in: source)
        var inTranslation = numberRuns(in: translation)

        // A month is a digit in Chinese and a word in English. 3月 becomes
        // "March", and a check that does not know this reports a dropped
        // figure on every dated document there is — which would be most of
        // the documents anyone puts through this app.
        for excused in monthsWrittenAsWords(source: source, translation: translation) {
            if let index = inSource.firstIndex(of: excused) {
                inSource.remove(at: index)
            }
        }
        // "3日内" translating to "within three days" is a translation, not a
        // dropped figure. Small numbers are spelled out in ordinary English
        // prose and it would be wrong to ask a translator not to.
        for excused in spelledOut(source: inSource, translation: translation) {
            if let index = inSource.firstIndex(of: excused) {
                inSource.remove(at: index)
            }
        }

        for number in inSource {
            if let index = inTranslation.firstIndex(of: number) {
                inTranslation.remove(at: index)
            }
        }
        for number in numberRuns(in: translation) {
            if let index = inSource.firstIndex(of: number) {
                inSource.remove(at: index)
            }
        }
        for excused in monthsWrittenAsWords(source: source, translation: translation) {
            if let index = inTranslation.firstIndex(of: excused) {
                inTranslation.remove(at: index)
            }
        }

        for missing in Set(inSource).sorted() {
            findings.append(
                IntegrityFinding(
                    kind: .droppedNumber,
                    severity: .blocking,
                    message: "\(missing) is in the source and not in the "
                        + "translation.",
                    evidence: missing
                )
            )
        }
        // Only a caution: a source may write its numbers as words, and a
        // correct translation is then entitled to a figure that is not in the
        // source as digits.
        for added in Set(inTranslation).sorted() {
            findings.append(
                IntegrityFinding(
                    kind: .inventedNumber,
                    severity: .caution,
                    message: "\(added) is in the translation and not in the "
                        + "source as digits.",
                    evidence: added
                )
            )
        }
        return findings
    }

    /// The numbers English writes as words. Stops at twelve because past it
    /// figures are the norm, and because a document's larger numbers are the
    /// ones worth being strict about.
    static let numberWords = [
        "1": "one", "2": "two", "3": "three", "4": "four", "5": "five",
        "6": "six", "7": "seven", "8": "eight", "9": "nine", "10": "ten",
        "11": "eleven", "12": "twelve"
    ]
    static let ordinalWords = [
        "1": "first", "2": "second", "3": "third", "4": "fourth",
        "5": "fifth", "6": "sixth", "7": "seventh", "8": "eighth",
        "9": "ninth", "10": "tenth", "11": "eleventh", "12": "twelfth"
    ]

    /// Which of the missing figures the translation wrote out in words.
    static func spelledOut(
        source: [String],
        translation: String
    ) -> [String] {
        let lowered = translation.lowercased()
        return source.filter { number in
            guard let word = numberWords[number] else { return false }
            if lowered.contains(word) { return true }
            if let ordinal = ordinalWords[number],
               lowered.contains(ordinal) { return true }
            return false
        }
    }

    static let monthNames = [
        "january", "february", "march", "april", "may", "june",
        "july", "august", "september", "october", "november", "december"
    ]

    /// The month numbers in the source that the translation spelled out.
    ///
    /// Only counted where the digit is actually in a month position — marked
    /// by 月 in Chinese — so a contract clause numbered 3 is still expected
    /// to appear as a 3.
    static func monthsWrittenAsWords(
        source: String,
        translation: String
    ) -> [String] {
        let lowered = translation.lowercased()
        var excused: [String] = []
        var digits = ""
        for character in source {
            if let scalar = character.unicodeScalars.first,
               character.unicodeScalars.count == 1,
               asciiDigit(scalar) != nil {
                digits.unicodeScalars.append(asciiDigit(scalar)!)
                continue
            }
            defer { digits = "" }
            guard character == "月", let month = Int(digits),
                  (1...12).contains(month) else { continue }
            let name = monthNames[month - 1]
            // The three-letter abbreviation counts: "15 Mar 2024" is not a
            // dropped month.
            if lowered.contains(name) || lowered.contains(name.prefix(3)) {
                excused.append(digits)
            }
        }
        return excused
    }

    /// Runs of digits, with full-width forms folded to ASCII and grouping
    /// separators removed. A decimal point is kept: it is part of the figure.
    public static func numberRuns(in text: String) -> [String] {
        var runs: [String] = []
        var current = ""
        var scalars = Array(text.unicodeScalars)
        scalars.append(" ")
        for scalar in scalars {
            if let digit = asciiDigit(scalar) {
                current.unicodeScalars.append(digit)
            } else if !current.isEmpty,
                      scalar == "." || scalar == "\u{FF0E}" {
                current.unicodeScalars.append(".")
            } else if !current.isEmpty, scalar == "," || scalar == "\u{FF0C}" {
                // A grouping comma, dropped, but only between digits — a
                // trailing one ends the run.
                continue
            } else if !current.isEmpty {
                while current.hasSuffix(".") { current.removeLast() }
                if !current.isEmpty { runs.append(current) }
                current = ""
            }
        }
        return runs
    }

    private static func asciiDigit(_ scalar: Unicode.Scalar) -> Unicode.Scalar? {
        if scalar.value >= 48, scalar.value <= 57 { return scalar }
        // Full-width ０ (U+FF10) through ９ (U+FF19).
        if scalar.value >= 0xFF10, scalar.value <= 0xFF19 {
            return Unicode.Scalar(scalar.value - 0xFF10 + 48)
        }
        return nil
    }

    // MARK: - Shape

    /// A phrase repeated four times running, which is what a model that has
    /// lost the thread produces and what a length check alone will not catch
    /// on a short block.
    public static func repeatedRun(in text: String) -> String? {
        let words = text
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        guard words.count >= 8 else { return nil }
        for size in 1...4 where words.count >= size * 4 {
            var index = 0
            while index + size * 4 <= words.count {
                let phrase = Array(words[index..<(index + size)])
                var repeats = 1
                var next = index + size
                while next + size <= words.count,
                      Array(words[next..<(next + size)]) == phrase {
                    repeats += 1
                    next += size
                }
                if repeats >= 4 {
                    return phrase.joined(separator: " ")
                }
                index += 1
            }
        }
        return nil
    }

    /// A model talking about the job instead of doing it. Matched on openings
    /// only: a translation may legitimately contain the word "translation",
    /// but a block that *starts* by announcing one is not a translation.
    public static func instructionLeak(in text: String) -> String? {
        let openings = [
            "here is the translation",
            "here's the translation",
            "translation:",
            "the translated text",
            "sure, here",
            "i cannot translate",
            "as an ai",
            "note:"
        ]
        let lowered = text.lowercased()
        for opening in openings where lowered.hasPrefix(opening) {
            return String(text.prefix(opening.count))
        }
        // The one that is not an opening: a small model announcing the job
        // mid-sentence — "The text “…” translates to “…”". Caught anywhere
        // in the first line, because the announcement is what makes it an
        // explanation rather than a translation, not where it sits.
        let firstLine = lowered
            .components(separatedBy: "\n")
            .first ?? lowered
        if firstLine.contains("translates to") {
            return "translates to"
        }
        return nil
    }

    private static func countingLetters(_ text: String) -> Int {
        text.unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0)
        }.count
    }

    private static func firstRun(
        of set: CharacterSet,
        in text: String
    ) -> String? {
        var run = ""
        for character in text {
            let isInSet = character.unicodeScalars.allSatisfy(set.contains)
            if isInSet {
                run.append(character)
                if run.count >= 24 { return run }
            } else if !run.isEmpty {
                return run
            }
        }
        return run.isEmpty ? nil : run
    }
}
