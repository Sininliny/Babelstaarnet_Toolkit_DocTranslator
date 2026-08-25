import Foundation

/// Where one sentence stops and the next one starts, as data rather than as
/// code.
///
/// Ported from Babelstårnet, where it was learned the hard way: a period is a
/// weak signal. Ordinals carry one — "den 15. september" — dates and list
/// numbers carry one, and a language may abbreviate heavily. Splitting on
/// periods alone cuts sentences in half.
///
/// The rules are supplied by the language rather than written here, because
/// the strongest signal the algorithm has — that a sentence opens with a
/// capital — is simply unavailable in a script without case, which is the
/// first script this app was pointed at.
public struct SentenceBoundaryRules: Sendable {
    /// Abbreviations whose period belongs to the word, not to the sentence.
    public let abbreviations: Set<String>
    /// Whether a sentence in this language opens with a capital, which is
    /// what lets a period followed by a lower-case word be read as an ordinal
    /// or an unlisted abbreviation rather than as a stop. False for Chinese,
    /// and declared rather than assumed.
    public let opensWithCapital: Bool
    /// Whether a lone letter before a period is an initial.
    public let singleLetterIsInitial: Bool
    public let stops: Set<Character>
    /// Stops that end a sentence on their own, with nothing following them.
    ///
    /// This is the rule the port could not do without. The parent algorithm
    /// requires whitespace after a stop — "17.30" and "www.au.dk" are periods
    /// inside a token, not sentence ends — and that test is correct for every
    /// language it was written for and wrong for Chinese, where 。 is followed
    /// immediately by the next sentence and a space would be a typesetting
    /// error. Without this set, a Chinese page has no sentence stops in it at
    /// all.
    public let standAloneStops: Set<Character>
    public let closers: Set<Character>
    public let openers: Set<Character>

    public init(
        abbreviations: Set<String> = [],
        opensWithCapital: Bool = true,
        singleLetterIsInitial: Bool = true,
        stops: Set<Character> = [".", "!", "?", "…"],
        standAloneStops: Set<Character> = [],
        closers: Set<Character> = ["\"", "'", "”", "’", "»", ")", "]", "}"],
        openers: Set<Character> = [
            "\"", "'", "“", "‘", "«", "(", "[", "{", "–", "—", "-"
        ]
    ) {
        self.abbreviations = abbreviations
        self.opensWithCapital = opensWithCapital
        self.singleLetterIsInitial = singleLetterIsInitial
        self.stops = stops
        self.standAloneStops = standAloneStops
        self.closers = closers
        self.openers = openers
    }
}

/// The algorithm. Generic; every answer it needs comes from the rules.
public struct SentenceBoundary: Sendable {
    private let rules: SentenceBoundaryRules
    private let locale: Locale

    public init(rules: SentenceBoundaryRules, locale: Locale) {
        self.rules = rules
        self.locale = locale
    }

    /// Where each sentence stop in `text` ends, as offsets into its UTF-16
    /// view. An offset is the first index *after* the stop and any closing
    /// quote or bracket that belongs to it.
    public func stopLocations(in text: String) -> [Int] {
        let source = text as NSString
        var locations: [Int] = []
        var index = 0
        while index < source.length {
            guard let end = stopEnd(at: index, in: source) else {
                index += 1
                continue
            }
            locations.append(end)
            index = end
        }
        return locations
    }

    /// Whether `text` runs all the way to a sentence stop.
    public func endsSentence(_ text: String) -> Bool {
        let source = text.trimmingCharacters(
            in: .whitespacesAndNewlines
        ) as NSString
        guard source.length > 0 else { return false }
        var index = source.length - 1
        while index > 0,
              let closer = character(at: index, in: source),
              rules.closers.contains(closer) {
            index -= 1
        }
        return stopEnd(at: index, in: source) == source.length
    }

    /// The sentences in `text`, as ranges over its UTF-16 view.
    public func sentenceRanges(in text: String) -> [NSRange] {
        let source = text as NSString
        var ranges: [NSRange] = []
        var start = 0
        for stop in stopLocations(in: text) where stop > start {
            ranges.append(NSRange(location: start, length: stop - start))
            var next = stop
            while next < source.length,
                  let space = character(at: next, in: source),
                  space.isWhitespace {
                next += 1
            }
            start = next
        }
        if start < source.length {
            ranges.append(
                NSRange(location: start, length: source.length - start)
            )
        }
        return ranges
    }

    /// The index just past a real sentence stop at `index`, or `nil` when the
    /// character there is not one, or is a period doing some other job.
    private func stopEnd(at index: Int, in source: NSString) -> Int? {
        guard let stop = character(at: index, in: source),
              rules.stops.contains(stop) else { return nil }

        var end = index + 1
        while end < source.length,
              let next = character(at: end, in: source),
              rules.stops.contains(next) || rules.closers.contains(next) {
            end += 1
        }

        // A stop that stands alone needs nothing after it and cannot be an
        // abbreviation or an ordinal, so it is settled here.
        if rules.standAloneStops.contains(stop) { return end }

        if end < source.length {
            guard let next = character(at: end, in: source),
                  next.isWhitespace else {
                // "17.30", "bl.a", "www.au.dk": a stop with the next word
                // pressed against it is punctuation inside a token.
                return nil
            }
            var following = end
            while following < source.length,
                  let candidate = character(at: following, in: source),
                  candidate.isWhitespace || rules.openers.contains(candidate) {
                following += 1
            }
            if let next = character(at: following, in: source),
               next.isNumber || (rules.opensWithCapital && next.isLowercase) {
                // A sentence here opens with a capital, so this period is an
                // ordinal or an abbreviation the list has not heard of.
                return nil
            }
        }

        guard stop == "." else { return end }
        let stem = wordStem(before: index, in: source).lowercased(with: locale)
        guard !stem.isEmpty else { return end }
        if stem.allSatisfy({ $0.isNumber || $0 == "." }) { return nil }
        if rules.abbreviations.contains(stem) { return nil }
        if rules.singleLetterIsInitial,
           stem.count == 1,
           stem.first?.isLetter == true {
            return nil
        }
        return end
    }

    /// The token in front of a period, interior periods included, so "bl.a."
    /// is read as one abbreviation rather than as the letter "a".
    private func wordStem(before index: Int, in source: NSString) -> String {
        var start = index
        while start > 0 {
            guard let previous = character(at: start - 1, in: source),
                  previous.isLetter
                    || previous.isNumber
                    || previous == "." else { break }
            start -= 1
        }
        guard start < index else { return "" }
        return source.substring(
            with: NSRange(location: start, length: index - start)
        )
    }

    private func character(at index: Int, in source: NSString) -> Character? {
        guard index >= 0, index < source.length else { return nil }
        let scalar = source.character(at: index)
        guard let unicode = UnicodeScalar(scalar) else { return nil }
        return Character(unicode)
    }
}

extension SourceLanguage {
    /// This language's sentence boundary, ready to use.
    public var sentenceBoundary: SentenceBoundary {
        SentenceBoundary(rules: sentenceRules, locale: Locale(identifier: identifier))
    }
}
