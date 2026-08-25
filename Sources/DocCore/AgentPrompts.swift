import Foundation

/// Every string this app is capable of sending to a model.
///
/// Collected in one file on purpose. The promise is that a document stays on
/// the machine; the smaller promise underneath it is that the app does not
/// send the model anything the user did not put in front of it. Both are
/// easier to check when there is exactly one place to look, and the file is
/// short enough to read in full.
///
/// The prompts are also where a design rule lives that is easy to lose: the
/// adjudicator is a *chooser*, never a writer. See `adjudication`.
public enum AgentPrompts {

    // MARK: - Reading a page

    public static func transcriptionInstructions(
        for language: SourceLanguage
    ) -> String {
        """
        You transcribe document pages. You copy what is printed; you never \
        translate, summarize, correct, or explain it.

        Rules:
        - Reproduce the text in \(language.promptName) exactly as printed, \
        including punctuation.
        - Follow the page's reading order. Keep one paragraph per line.
        - Skip page numbers and running heads.
        - If a character is illegible, write ⍰ in its place rather than \
        guessing a character that would fit.
        - Output nothing but the transcription: no preamble, no commentary, \
        no markdown fences.
        """
    }

    public static func transcriptionRequest(
        for language: SourceLanguage
    ) -> String {
        "Transcribe every line of \(language.promptName) text on this page."
    }

    /// A model's transcription into blocks — one per sentence, the same unit
    /// the recognizer's reading is cut into.
    ///
    /// Splitting here is what makes the two readings comparable at all. Left
    /// as returned, the model gives one block per printed line and the
    /// recognizer gives one per run of similar-looking lines; on a page with
    /// even spacing that was twenty-four against two, and no alignment can
    /// bridge a factor of twelve. Cut both at sentence stops and they land on
    /// the same units.
    ///
    /// The model returns no geometry, so its blocks carry the whole page as
    /// their box. Nothing downstream aligns this reader on geometry — the
    /// reconciler matches it to the recognizer by what the two say, which is
    /// the only thing they have in common.
    public static func blocks(
        fromTranscription response: String,
        pageIndex: Int,
        language: SourceLanguage
    ) -> [SourceBlock] {
        let boundary = language.sentenceBoundary
        var blocks: [SourceBlock] = []

        for line in stripFences(response).components(separatedBy: "\n") {
            let text = language.normalizeReading(line)
            guard !text.isEmpty else { continue }
            let source = text as NSString
            for range in boundary.sentenceRanges(in: text) {
                let sentence = source.substring(with: range)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !sentence.isEmpty else { continue }
                blocks.append(
                    SourceBlock(
                        pageIndex: pageIndex,
                        order: blocks.count,
                        box: .full,
                        kind: .paragraph,
                        lines: [sentence],
                        text: sentence,
                        confidence: nil
                    )
                )
            }
        }
        return blocks
    }

    /// The announcement a small model puts in front of a translation.
    ///
    /// "The text \"申请执行人：…\" translates to \"Applicant for
    /// Enforcement: …\"" is a real answer from a 3B model that had just been
    /// told, in the instructions, not to do this. Telling it again does not
    /// work reliably; removing the preamble does, and costs nothing when
    /// there is none.
    ///
    /// Conservative on purpose. It only fires when what follows the
    /// announcement is non-empty, so a translation that happens to begin
    /// "The text of the agreement…" is left alone.
    public static func stripPreamble(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()
        let announcements = [
            "translates to",
            "translation:",
            "the translation is",
            "here is the translation",
            "here's the translation",
            "in english:"
        ]
        // Only in the opening — well past the start it is prose, not a
        // preamble.
        let window = String(lowered.prefix(160))
        guard let announcement = announcements.first(where: window.contains),
              let range = lowered.range(of: announcement) else {
            return trimmed
        }
        var rest = String(trimmed[range.upperBound...])
            .trimmingCharacters(in: CharacterSet(charactersIn: " :\n\t"))
        // The answer is usually quoted after the announcement.
        if rest.hasPrefix("\"") || rest.hasPrefix("“") {
            rest = String(rest.dropFirst())
            if let end = rest.lastIndex(where: { $0 == "\"" || $0 == "”" }) {
                rest = String(rest[rest.startIndex..<end])
            }
        }
        rest = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        return rest.isEmpty ? trimmed : rest
    }

    /// Models wrap output in code fences however plainly they are told not
    /// to, and a stray ``` in the source text would otherwise become part of
    /// a translation.
    public static func stripFences(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        while let first = lines.first,
              first.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
            lines.removeFirst()
        }
        while let last = lines.last,
              last.trimmingCharacters(in: .whitespaces).hasPrefix("```")
                || last.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Settling a disagreement

    public static let choiceA = "A"
    public static let choiceB = "B"
    public static let adjudicationChoices = [choiceA, choiceB]

    /// The adjudicator picks between two readings. It is never asked to write
    /// a third.
    ///
    /// This is the most important restraint in the app. A model allowed to
    /// *correct* a disputed line will, sometimes, produce a fluent sentence
    /// that neither reader saw and that is not on the page — and nothing
    /// downstream can catch that, because a hallucinated source sentence
    /// translates perfectly, passes every integrity check, and reads better
    /// than the truth. A model that can only choose between two candidates
    /// can be wrong, but it can only ever be wrong about something that was
    /// actually printed.
    ///
    /// So the cost of the restraint is a wrong choice now and then; the cost
    /// of lifting it is a document that quietly says something the original
    /// did not. The interface shows both candidates for exactly this reason.
    public static func adjudicationInstructions(
        for language: SourceLanguage
    ) -> String {
        """
        Two systems read the same block of \(language.promptName) text from a \
        scanned page and produced different results. Exactly one of them is \
        closer to what is printed.

        Judge by what is likely to be *printed*, not by what reads best:
        - A reading whose characters make a grammatical, sensible sentence is \
        usually the right one.
        - A reading with a character that is visually similar to a sensible \
        one but makes no sense is usually the misrecognition.
        - Numbers, dates, and names cannot be judged this way. Where the two \
        disagree only on a digit, prefer reading A, which came from a \
        character recognizer rather than from a language model.

        Answer with exactly one character: A or B. Nothing else.
        """
    }

    public static func adjudicationPrompt(
        contextBefore: String?,
        candidateA: String,
        candidateB: String
    ) -> String {
        var prompt = ""
        if let contextBefore, !contextBefore.isEmpty {
            prompt += "The block before this one reads:\n"
                + String(contextBefore.suffix(200)) + "\n\n"
        }
        prompt += """
            A: \(candidateA)

            B: \(candidateB)

            Which is closer to what is printed? Answer A or B.
            """
        return prompt
    }

    // MARK: - Reading the whole document first

    public static let kindMarker = "KIND:"
    public static let subjectMarker = "SUBJECT:"
    public static let registerMarker = "REGISTER:"
    public static let termMarker = "TERM:"
    public static let noteMarker = "NOTE:"

    /// Asks what the document is before asking for a word of it to be
    /// translated.
    ///
    /// The terms are the valuable part. A model asked to translate one
    /// sentence at a time will render 甲方 as "Party A" here and "the first
    /// party" three sentences later, and both readings are defensible on
    /// their own line — which is why nothing downstream catches it and why
    /// the document reads as though two people translated it. Deciding once,
    /// in advance, and handing the decision to every call is the only thing
    /// that fixes it.
    public static func documentProfileInstructions(
        languages: LanguagePair
    ) -> String {
        """
        You are about to translate a document from \
        \(languages.source.promptName) into \(languages.target.promptName). \
        First, read it and say what it is, so that every sentence can be \
        translated as part of the same document rather than on its own.

        What you are shown is taken from across the document and marked with \
        the page each part came from. It is not continuous: expect gaps \
        between the parts, and do not try to account for them.

        Answer in exactly this form and nothing else:

        \(kindMarker) <what kind of document this is, a few words>
        \(subjectMarker) <what it is about, one line>
        \(registerMarker) <how the \(languages.target.promptName) should \
        sound: formal legal, plain official, technical, personal>
        \(termMarker) <a term in \(languages.source.promptName)> | <how it \
        should be rendered every time it appears>
        \(noteMarker) <anything a translator seeing only one sentence of \
        this would get wrong>

        Give up to eight TERM lines. Choose the terms that recur and that \
        have more than one defensible translation — parties, defined terms, \
        terms of art, names of bodies. Do not list words with only one \
        possible rendering; a glossary of the obvious crowds out the entries \
        that matter.

        Give at most three NOTE lines, and none at all if nothing needs \
        saying.
        """
    }

    public static func documentProfilePrompt(sample: String) -> String {
        """
        Here is the document:

        \(sample)
        """
    }

    public static func profile(from answer: String) -> DocumentProfile {
        var profile = DocumentProfile()
        for line in stripFences(answer).components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            func value(_ marker: String) -> String {
                String(trimmed.dropFirst(marker.count))
                    .trimmingCharacters(in: .whitespaces)
            }
            if trimmed.hasPrefix(kindMarker) {
                profile.kind = value(kindMarker)
            } else if trimmed.hasPrefix(subjectMarker) {
                profile.subject = value(subjectMarker)
            } else if trimmed.hasPrefix(registerMarker) {
                profile.register = value(registerMarker)
            } else if trimmed.hasPrefix(noteMarker) {
                let note = value(noteMarker)
                if !note.isEmpty, profile.notes.count < 3 {
                    profile.notes.append(note)
                }
            } else if trimmed.hasPrefix(termMarker) {
                let parts = value(termMarker).components(separatedBy: "|")
                guard parts.count >= 2 else { continue }
                let source = parts[0].trimmingCharacters(in: .whitespaces)
                let target = parts.dropFirst()
                    .joined(separator: "|")
                    .trimmingCharacters(in: .whitespaces)
                guard !source.isEmpty, !target.isEmpty,
                      profile.terms.count < 8 else { continue }
                profile.terms[source] = target
            }
        }
        return profile
    }

    // MARK: - Translating

    public static func translationInstructions(
        languages: LanguagePair,
        brief: TranslationBrief = .none,
        profile: DocumentProfile = .unknown
    ) -> String {
        let style = languages.target.styleGuidance
            .map { "- " + $0 }
            .joined(separator: "\n")
        var instructions = """
            You translate \(languages.source.promptName) into \
            \(languages.target.promptName).

            \(style)
            - Output only the translation. No notes, no alternatives, no \
            explanation of your choices, no quotation marks around the whole \
            answer.
            - Never begin with "The text", "This translates to", \
            "Translation:", or any other announcement. The first word of your \
            answer is the first word of the translation.
            - Never repeat the \(languages.source.promptName) back.
            - If the text is a heading, translate it as a heading.
            """

        // What the document is, before what the reader asked for: the
        // profile is the app's own reading and the brief is the reader's
        // decision, and where they disagree the reader wins.
        if !profile.isEmpty {
            instructions += """

                What you are translating:
                \(profile.guidanceLines().map { "- " + $0 }.joined(separator: "\n"))
                """
        }

        // The reader's instructions come after the house style and are
        // stated as overriding it, because that is what they are for: an
        // instruction that cannot beat a default is decoration.
        if brief.isEmpty {
            instructions += "\n- Never leave "
                + "\(languages.source.promptName) characters in the output."
        } else {
            instructions += """

                The reader has asked for the following. Where it conflicts \
                with anything above, follow the reader:
                \(brief.guidanceLines.map { "- " + $0 }.joined(separator: "\n"))
                """
        }
        return instructions
    }

    public static func translationPrompt(
        text: String,
        kind: BlockKind,
        documentContext: String?,
        terms: [GlossaryTerm] = [],
        following context: TranslationContext = .none
    ) -> String {
        var prompt = ""
        // The sentence before this one, and what it was translated as. The
        // English half is what keeps a recurring term rendered the same way
        // twenty sentences apart, and what lets a pronoun or a "the said
        // party" resolve to something.
        if let source = context.previousSource, !source.isEmpty {
            prompt += "The previous sentence reads:\n"
                + String(source.suffix(200)) + "\n"
            if let target = context.previousTarget, !target.isEmpty {
                prompt += "You translated it as:\n"
                    + String(target.suffix(200)) + "\n"
            }
            prompt += "\nTranslate only what follows.\n\n"
        }
        // Only the terms that occur in this block. A glossary of two hundred
        // entries repeated in front of every block is mostly noise, and a
        // model that has to find the relevant line will sometimes apply the
        // wrong one.
        if !terms.isEmpty {
            prompt += "For this text specifically:\n"
                + terms.map { "- " + $0.instruction }
                    .joined(separator: "\n")
                + "\n\n"
        }
        if let documentContext, !documentContext.isEmpty {
            prompt += "This is from a document titled: "
                + String(documentContext.prefix(120)) + "\n\n"
        }
        if kind == .heading {
            prompt += "Translate this heading:\n"
        } else {
            prompt += "Translate this text:\n"
        }
        return prompt + text
    }

    // MARK: - Reviewing

    public static let verdictMarker = "VERDICT:"
    public static let revisionMarker = "REVISION:"
    public static let verdictAccurate = "ACCURATE"
    public static let verdictRevise = "REVISE"

    /// The reviewer reads the source and the draft together, and it *is*
    /// allowed to rewrite — the draft is the app's own output, not the
    /// user's document, so a rewrite cannot invent something the source never
    /// said without the mechanical checks in `TextIntegrity` noticing.
    /// - Parameter agreedTerms: the renderings the document settled on that
    ///   occur in *this* block. The reviewer has no glossary of its own — it
    ///   is handed a source and a draft — so if it is not told here that the
    ///   document already calls 被执行人 something, it will read a block that
    ///   calls it something else and approve it, correctly, on its own terms.
    public static func reviewInstructions(
        languages: LanguagePair,
        brief: TranslationBrief = .none,
        profile: DocumentProfile = .unknown,
        agreedTerms: [String] = []
    ) -> String {
        var instructions = """
        You check translations from \(languages.source.promptName) into \
        \(languages.target.promptName). You are the second pair of eyes, not \
        the translator: leave a sound translation alone.

        Look for, in this order:
        1. Meaning that changed — a negation dropped, a condition inverted, \
        an obligation turned into a permission.
        2. Anything in the source that is missing from the translation.
        3. Anything in the translation that is not in the source.
        4. Numbers, dates, names, and units that do not match.
        5. \(languages.source.promptName) left untranslated.

        Do not rewrite for style. Fluency is not a defect.

        Answer in this exact form:
        \(verdictMarker) \(verdictAccurate)
        or
        \(verdictMarker) \(verdictRevise)
        \(revisionMarker) <the corrected translation, and nothing else>
        """
        if !profile.isEmpty {
            let lines = profile.guidanceLines() + agreedTerms
            instructions += """

                This block is part of a larger document:
                \(lines.map { "- " + $0 }.joined(separator: "\n"))
                A rendering that disagrees with the rest of the document is a \
                defect even when it is defensible on its own. You are seeing \
                one block; the reader will see all of them together.
                """
        }
        guard !brief.isEmpty else { return instructions }
        // The reviewer is given the brief too. A translator that quietly
        // ignored an instruction and a reviewer that never heard of it will
        // agree perfectly on a translation the reader did not ask for.
        instructions += """

            The reader asked for the following, and a translation that \
            ignores it needs revising even if it is otherwise correct:
            \(brief.guidanceLines.map { "- " + $0 }.joined(separator: "\n"))
            """
        return instructions
    }

    public static func reviewPrompt(
        source: String,
        draft: String,
        languages: LanguagePair
    ) -> String {
        """
        \(languages.source.promptName):
        \(source)

        \(languages.target.promptName):
        \(draft)
        """
    }

    /// What a reviewer said, recovered from an answer that may not have
    /// followed the form.
    public struct ReviewVerdict: Sendable, Equatable {
        public let isAccurate: Bool
        public let revision: String?

        public init(isAccurate: Bool, revision: String?) {
            self.isAccurate = isAccurate
            self.revision = revision
        }
    }

    // MARK: - Asking the reader

    /// Questions raised before translating, not complaints filed after.
    ///
    /// The model is told to ask only about things that would change the
    /// English. That constraint is the whole design: a model invited to be
    /// curious will produce five interesting questions about any document,
    /// the reader will answer them out of politeness, and the app will have
    /// spent its one chance to interrupt on nothing.
    public static func clarificationInstructions(
        languages: LanguagePair
    ) -> String {
        """
        You are about to translate a document from \
        \(languages.source.promptName) into \(languages.target.promptName). \
        Before you start, you may ask the reader up to three questions about \
        it.

        Ask only where the answer would change the \
        \(languages.target.promptName) — an ambiguity that has two defensible \
        translations, a term of art that means different things in different \
        fields, a form of address whose register depends on who the document \
        is for, a name that may be a person, a company, or a place.

        Do not ask about anything you can settle by reading the text. Do not \
        ask what the document is for out of interest. Do not ask about \
        formatting. If nothing genuinely hangs on an answer, ask nothing.

        For each question, offer two or three concrete options. Write each \
        option as a short label, then a vertical bar, then the instruction a \
        translator should follow if the reader picks it.

        Answer in exactly this form and nothing else:

        \(questionMarker) <the question>
        \(evidenceMarker) <the phrase from the document that raises it>
        \(optionMarker) <label> | <instruction for the translator>
        \(optionMarker) <label> | <instruction for the translator>

        Repeat the block for each further question. If you have no questions, \
        answer with the single word \(noQuestionsMarker).
        """
    }

    public static let questionMarker = "QUESTION:"
    public static let evidenceMarker = "BECAUSE:"
    public static let optionMarker = "OPTION:"
    public static let noQuestionsMarker = "NONE"

    /// - Parameter sample: text taken from across the document, marked with
    ///   the page each part came from. Not the beginning of it: the question
    ///   worth asking is as likely to be raised by a defined term on page
    ///   nine as by the letterhead, and it still has to be asked before page
    ///   one is translated.
    public static func clarificationPrompt(sample: String) -> String {
        """
        Here is the document. It is taken from across it and marked with the \
        page each part came from, so expect gaps between the parts.

        \(sample)
        """
    }

    /// The reader's own "I'm not sure" is appended to every question here
    /// rather than asked for in the prompt, so a model cannot omit it.
    public static func questions(
        from answer: String,
        limit: Int = 3
    ) -> [ClarificationQuestion] {
        let text = stripFences(answer)
        guard !text.uppercased().hasPrefix(noQuestionsMarker) else { return [] }

        var questions: [ClarificationQuestion] = []
        var question: String?
        var evidence: String?
        var options: [ClarificationOption] = []

        func flush() {
            defer {
                question = nil
                evidence = nil
                options = []
            }
            guard let question, !question.isEmpty, options.count >= 2 else {
                return
            }
            questions.append(
                ClarificationQuestion(
                    question: question,
                    options: options + [.unsure],
                    evidence: evidence
                )
            )
        }

        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(questionMarker) {
                flush()
                question = String(trimmed.dropFirst(questionMarker.count))
                    .trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix(evidenceMarker) {
                evidence = String(trimmed.dropFirst(evidenceMarker.count))
                    .trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix(optionMarker) {
                let body = String(trimmed.dropFirst(optionMarker.count))
                let parts = body.components(separatedBy: "|")
                guard parts.count >= 2 else { continue }
                let label = parts[0].trimmingCharacters(in: .whitespaces)
                let guidance = parts.dropFirst()
                    .joined(separator: "|")
                    .trimmingCharacters(in: .whitespaces)
                guard !label.isEmpty, !guidance.isEmpty else { continue }
                options.append(
                    ClarificationOption(label: label, guidance: guidance)
                )
            }
        }
        flush()
        return Array(questions.prefix(limit))
    }

    public static func verdict(from answer: String) -> ReviewVerdict {
        let text = stripFences(answer)
        let upper = text.uppercased()

        guard let range = upper.range(of: revisionMarker) else {
            // No revision offered. Treated as approval unless the model said
            // otherwise — a reviewer that says "REVISE" and then supplies
            // nothing has not reviewed anything, and its silence must not
            // overwrite a translation with an empty string.
            let saysRevise = upper.contains(verdictRevise)
            return ReviewVerdict(isAccurate: !saysRevise, revision: nil)
        }

        let revision = String(text[range.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !revision.isEmpty else {
            return ReviewVerdict(isAccurate: false, revision: nil)
        }
        return ReviewVerdict(isAccurate: false, revision: revision)
    }
}
