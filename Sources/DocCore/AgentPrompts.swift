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

        for line in stripWrapping(response).components(separatedBy: "\n") {
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

    /// The reasoning a thinking model emits before its answer.
    ///
    /// Qwen3 and everything like it open a `<think>` block by default, reason
    /// in it at length, and only then answer. Left in, that block becomes the
    /// translation: a paragraph of the model talking to itself about how to
    /// render 甲方, drawn onto the page where the English should be. It is
    /// not a preamble in the sense `stripPreamble` handles — it is longer
    /// than the answer, it is delimited, and it is the majority of what the
    /// model returns.
    ///
    /// Three shapes, because all three occur. A balanced block anywhere in
    /// the answer is removed. A closing tag with no opening one — the chat
    /// template opened the block on the model's behalf — means everything
    /// before it was reasoning. An opening tag with no closing one means the
    /// model spent its whole token budget thinking and never answered, so
    /// what is kept is whatever preceded it, which is usually nothing: an
    /// empty answer is the truth there, and the caller already knows what to
    /// do with one.
    public static func stripReasoning(_ text: String) -> String {
        var output = text
        while let open = output.range(of: "<think>"),
              let close = output.range(
                  of: "</think>",
                  range: open.upperBound..<output.endIndex
              ) {
            output.replaceSubrange(open.lowerBound..<close.upperBound, with: "")
        }
        if let close = output.range(of: "</think>", options: .backwards) {
            output = String(output[close.upperBound...])
        }
        if let open = output.range(of: "<think>") {
            output = String(output[..<open.lowerBound])
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Everything a model puts around its answer that is not the answer:
    /// the reasoning block first, then the code fences. In that order,
    /// because a fenced answer inside a reasoning block is reasoning.
    public static func stripWrapping(_ text: String) -> String {
        stripFences(stripReasoning(text))
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
    public static let fieldMarker = "FIELD:"
    public static let subjectMarker = "SUBJECT:"
    public static let backgroundMarker = "BACKGROUND:"
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
        \(fieldMarker) <the field it belongs to, one of: \
        \(DocumentField.choices.map(\.promptName).joined(separator: ", "))>
        \(subjectMarker) <what it is about, one line>
        \(backgroundMarker) <the situation this document is part of, two or \
        three sentences: who the parties are to each other, what has already \
        happened, and what this document is meant to bring about>
        \(registerMarker) <how the \(languages.target.promptName) should \
        sound: formal legal, plain official, technical, personal>
        \(termMarker) <a term in \(languages.source.promptName)> | <how it \
        should be rendered every time it appears>
        \(noteMarker) <anything a translator seeing only one sentence of \
        this would get wrong>

        The field is not a label. It decides what the things in this \
        document are called — whether a substance is named by its generic \
        name or its brand name, whether a body is named by its own English \
        name or a description of it — so answer it even when the document \
        is unremarkable.

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
        for line in stripWrapping(answer).components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            func value(_ marker: String) -> String {
                String(trimmed.dropFirst(marker.count))
                    .trimmingCharacters(in: .whitespaces)
            }
            if trimmed.hasPrefix(kindMarker) {
                profile.kind = value(kindMarker)
            } else if trimmed.hasPrefix(fieldMarker) {
                profile.field = DocumentField(describing: value(fieldMarker))
            } else if trimmed.hasPrefix(backgroundMarker) {
                profile.background = value(backgroundMarker)
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
        // A model that answered the rest of the form and skipped the field
        // has usually said it anyway: "a discharge summary" is medicine and
        // "an enforcement notice" is law. Inferring is worth doing because
        // the alternative is not a neutral default — it is a document
        // translated with no naming conventions at all, which is the
        // behaviour this whole stage exists to replace.
        if !profile.field.isKnown {
            profile.field = DocumentField(
                describing: profile.kind + " " + profile.subject
            )
        }
        return profile
    }

    // MARK: - Looking the names up

    public static let nameMarker = "NAME:"
    public static let unknownName = "UNKNOWN"
    public static let noNamesMarker = "NONE"

    /// Asks what the things in this document are already called.
    ///
    /// A separate call from the profile, and the separation is not tidiness.
    /// The profile asks a model to *decide* — which of two defensible
    /// renderings this document will use for 甲方 — and the right answer is
    /// whichever one it applies consistently. This asks it to *remember*: 布洛芬
    /// is ibuprofen, and no amount of consistency makes "Buluofen" right.
    /// Those are different jobs, they fail in different ways, and the
    /// instruction that makes one reliable is the instruction that ruins the
    /// other. A model asked to settle a term should be decisive; a model
    /// asked to recall a name should say when it does not know.
    ///
    /// Which is the rule this prompt spends most of its words on. An invented
    /// name is the worst output this app can produce: it is fluent, it is
    /// specific, it passes every mechanical check, and it is the one thing
    /// the reader cannot verify — they came here because they cannot read the
    /// source. UNKNOWN costs a transliteration the reader can see and
    /// question. A guess costs them a drug that does not exist.
    public static func nameInstructions(
        languages: LanguagePair,
        profile: DocumentProfile,
        brief: TranslationBrief = .none,
        limit: Int = 20
    ) -> String {
        var instructions = """
            You are preparing a document to be translated from \
            \(languages.source.promptName) into \
            \(languages.target.promptName). You are not translating it. \
            Your job is to find the names in it that already have an \
            established \(languages.target.promptName) form, and to say what \
            that form is.

            A name has an established form when \
            \(languages.target.promptName) already calls the thing \
            something: a medicine's international nonproprietary name, a \
            company's registered name, an institution's own name for itself, \
            a statute's official title, a standard's designation, a place's \
            usual spelling, the published title of a work. These are looked \
            up, not translated — nothing in the characters leads to them.
            """

        // What the document is, because it is what makes the difference
        // between a useful list and a list of the obvious. The same three
        // characters are a drug on a prescription and a company on an
        // invoice, and a model that has been told which is looking for one
        // kind of answer rather than any.
        let context = profile.guidanceLines()
        if !context.isEmpty {
            instructions += """


                What you are reading:
                \(context.map { "- " + $0 }.joined(separator: "\n"))
                """
        }
        if !brief.isEmpty {
            instructions += """


                The reader has said this about it:
                \(brief.guidanceLines.map { "- " + $0 }.joined(separator: "\n"))
                """
        }

        instructions += """


            Answer with one line per name and nothing else:

            \(nameMarker) <the name as printed in the source> | <its \
            established \(languages.target.promptName) form> | <what makes \
            that its name, in a few words>

            Four rules, and the first matters more than being thorough:

            - If you are not certain of the established form, write \
            \(unknownName) in place of it. That answer is useful. An \
            invented one is not: a name nobody can look up reads exactly \
            like a real one, and the reader cannot check it — not reading \
            \(languages.source.promptName) is why they are here.
            """
        if let romanization = languages.source.romanization {
            instructions += """

                - Never offer \(romanization.name) as the established form. \
                Spelling the characters out is what this list exists to \
                prevent, and a name spelled out is a name not found: write \
                \(unknownName) instead.
                """
        }
        instructions += """

            - Do not list a private individual's name. Those have no \
            established form and are transliterated.
            - Do not list anything you would translate rather than look up: \
            an ordinary word, a phrase, a description of something.

            Up to \(limit) names. If the document contains none, answer with \
            the single word \(noNamesMarker).
            """
        return instructions
    }

    public static func namePrompt(sample: String) -> String {
        """
        Here is the document. It is taken from across it and marked with the \
        page each part came from, so expect gaps between the parts.

        \(sample)
        """
    }

    /// The names a model was sure of, and only those.
    ///
    /// - Parameter language: the source language, so an answer that spelled a
    ///   name out instead of recalling it can be dropped. The model is told
    ///   not to do this; dropping it is what makes the instruction hold. A
    ///   rendering identical to the source's own romanization has recorded
    ///   the mistake as though it were the answer, and it would then suppress
    ///   the mechanical check that would otherwise have caught it in every
    ///   block — the one case where a wrong entry is worse than no entry.
    public static func names(
        from answer: String,
        language: SourceLanguage,
        limit: Int = 20
    ) -> [ResolvedName] {
        let text = stripWrapping(answer)
        guard !text.uppercased().hasPrefix(noNamesMarker) else { return [] }

        var names: [ResolvedName] = []
        var seen = Set<String>()
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(nameMarker) else { continue }
            let parts = String(trimmed.dropFirst(nameMarker.count))
                .components(separatedBy: "|")
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count >= 2 else { continue }
            let source = parts[0]
            let rendering = parts[1]
            guard !source.isEmpty, !rendering.isEmpty,
                  rendering != source,
                  !rendering.uppercased().contains(unknownName),
                  !seen.contains(source),
                  !isRomanization(rendering, of: source, in: language)
            else { continue }
            seen.insert(source)
            let basis = parts.count > 2 && !parts[2].isEmpty
                ? parts[2]
                : nil
            names.append(
                ResolvedName(
                    source: source,
                    rendering: rendering,
                    basis: basis
                )
            )
            guard names.count < limit else { break }
        }
        return names
    }

    /// Whether a rendering is just the source spelled out.
    static func isRomanization(
        _ rendering: String,
        of source: String,
        in language: SourceLanguage
    ) -> Bool {
        guard let romanization = language.romanization else { return false }
        let syllables = romanization.syllables(source)
        guard !syllables.isEmpty else { return false }
        let letters = rendering.lowercased().filter(\.isLetter)
        return String(letters) == syllables.joined()
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
            - A name that \(languages.target.promptName) already has takes \
            the form \(languages.target.promptName) gives it: a medicine \
            its generic name, a company its registered name, a body the name \
            it uses for itself, a law or a published work its own title, a \
            place its usual spelling. These are recalled, not rendered.
            """
        // Named, because an instruction that names the mistake is followed
        // where one that describes it is not. "Do not transliterate" is
        // advice; "Pinyin is not English" is a rule about a specific thing
        // the model is about to do.
        if let romanization = languages.source.romanization {
            instructions += """

                - \(romanization.name) is not \
                \(languages.target.promptName). Spell a name out only when \
                it has no established \(languages.target.promptName) form — \
                a private person's name, most of all — and never as a way of \
                getting past one you cannot recall.
                """
        }

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

    /// One block, with as much of the page around it as it turned out to
    /// need.
    ///
    /// The order is deliberate and it is the part that keeps a small model
    /// honest. Everything that is context comes first and is labelled as
    /// context; the block to translate comes last, immediately after the
    /// instruction to translate it, and nothing follows it. A model handed a
    /// sentence in the middle of a prompt will sometimes translate the whole
    /// prompt; a model handed one at the end of it rarely does.
    ///
    /// What is included is decided by `AdaptiveContext`, not here. See
    /// `ContextNeed` for why that is a decision at all.
    public static func translationPrompt(
        text: String,
        kind: BlockKind,
        documentContext: String?,
        terms: [GlossaryTerm] = [],
        following context: TranslationContext = .none,
        need: ContextNeed = .none
    ) -> String {
        var prompt = ""
        var hasContext = false

        if let documentContext, !documentContext.isEmpty {
            prompt += "This is from a document titled: "
                + String(documentContext.prefix(120)) + "\n\n"
        }
        // The heading first, because it is the widest thing here: it says
        // what the whole section is, and a row of a table means whatever its
        // column says it means.
        if need.heading, let heading = context.sectionHeading,
           !heading.isEmpty {
            prompt += "It sits under the heading:\n"
                + String(heading.prefix(120)) + "\n\n"
            hasContext = true
        }
        // The sentence before, as printed. Withheld from a block that stands
        // on its own: it is the piece a model is most likely to mistake for
        // the thing it was asked to translate.
        if need.previousSource, let source = context.previousSource,
           !source.isEmpty {
            prompt += "The line before it reads:\n"
                + String(source.suffix(200)) + "\n"
            hasContext = true
        }
        // And the English it became. The floor, and the cheap half: it is
        // already in the target language, so it cannot be mistaken for
        // something to translate, and it is what keeps a recurring term
        // rendered the same way twenty sentences apart.
        if need.previousTarget, let target = context.previousTarget,
           !target.isEmpty {
            prompt += "The line before it was translated as:\n"
                + String(target.suffix(200)) + "\n"
            hasContext = true
        }
        // And, for a heading or a fragment, what comes after it. A heading is
        // named by the section under it: 执行 is "enforcement" over a court
        // order and "execution" over a build script, and the heading itself
        // contains nothing that decides which.
        if need.following, let next = context.nextSource, !next.isEmpty {
            prompt += "The line after it reads:\n"
                + String(next.prefix(200)) + "\n"
            hasContext = true
        }
        if hasContext {
            prompt += "\nThat is context. Do not translate any of it.\n\n"
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
        if kind == .heading {
            prompt += "Translate this heading, and nothing else:\n"
        } else {
            prompt += "Translate this text, and nothing else:\n"
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
    /// - Parameter agreedNames: the names in *this* block that were looked
    ///   up when the document was read. Given for the same reason as the
    ///   terms and with more at stake: a reviewer that has not been told what
    ///   the drug is called will read "Buluofen", find it consistent with a
    ///   source it can see says 布洛芬, and approve it.
    /// - Parameter agreedTerms: the renderings the document settled on that
    ///   occur in *this* block. The reviewer has no glossary of its own — it
    ///   is handed a source and a draft — so if it is not told here that the
    ///   document already calls 被执行人 something, it will read a block that
    ///   calls it something else and approve it, correctly, on its own terms.
    public static func reviewInstructions(
        languages: LanguagePair,
        brief: TranslationBrief = .none,
        profile: DocumentProfile = .unknown,
        agreedTerms: [String] = [],
        agreedNames: [String] = []
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
        6. A name spelled out syllable by syllable where \
        \(languages.target.promptName) has a name of its own for the thing — \
        a medicine, a company, a body, a law, a place. This one does not \
        look like a defect: it reads as a word, and it is the only error \
        here that a reader who cannot read \
        \(languages.source.promptName) has no way to catch.

        Do not rewrite for style. Fluency is not a defect.

        Answer in this exact form:
        \(verdictMarker) \(verdictAccurate)
        or
        \(verdictMarker) \(verdictRevise)
        \(revisionMarker) <the corrected translation, and nothing else>
        """
        if !profile.isEmpty {
            let lines = profile.guidanceLines() + agreedTerms + agreedNames
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
        let text = stripWrapping(answer)
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
        let text = stripWrapping(answer)
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
