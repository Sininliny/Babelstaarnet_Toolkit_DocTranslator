import DocAgents
import DocCore
import Foundation
import LanguageChinese

/// Names that are looked up rather than translated, and the one mistake this
/// app most needs not to make.
///
/// The document under check is a prescription, because that is where the
/// stakes are plainest. 布洛芬 is ibuprofen; a translator that spells the
/// characters out writes "Buluofen", which names no medicine in any language
/// and sits in an English sentence that reads perfectly. Every other check in
/// this project passes it: the reading was right, the doses match, the length
/// is plausible, and the reviewing model agrees the English says what the
/// Chinese says. So these checks are about the two things that do catch it —
/// asking the right question before translating, and spelling the source out
/// afterwards to see whether the answer came back.
func runNameChecks(_ report: Report) async {
    let languages = SimplifiedChinese.toEnglish

    report.begin("names/pinyin")

    report.equal(
        SimplifiedChinese.syllables(of: "布洛芬"),
        ["bu", "luo", "fen"],
        "a run of characters spells out one syllable per character"
    )
    report.equal(
        SimplifiedChinese.syllables(of: "布洛芬。"),
        [],
        "a run with punctuation in it does not spell out at all"
    )
    report.equal(
        SimplifiedChinese.syllables(of: "Aspirin"),
        [],
        "and neither does text that is already in Latin letters"
    )
    report.equal(
        SimplifiedChinese.syllables(of: ""),
        [],
        "nor nothing"
    )

    report.begin("names/field")

    report.equal(
        DocumentField(describing: "a hospital discharge summary"),
        .medicine,
        "a description of a document names its field"
    )
    report.equal(
        DocumentField(describing: "a court enforcement notice"),
        .law,
        "and so does another"
    )
    report.equal(
        DocumentField(describing: "something else entirely"),
        .unknown,
        "a description that says nothing leaves the field unknown"
    )
    // The reader's answer comes back as the label they clicked, and the field
    // has to be recoverable from it — otherwise the app asks the one question
    // that changes every name in the document and then throws the answer
    // away.
    for field in DocumentField.choices {
        report.equal(
            DocumentField(describing: "\(field.label) — \(field.consequence)"),
            field,
            "\(field.label) survives being asked and answered"
        )
    }
    report.expect(
        DocumentField.clarification.options.count
            == DocumentField.choices.count + 1,
        "every field is offered, and so is “I'm not sure”"
    )
    report.expect(
        DocumentField.medicine.namingConventions.contains {
            $0.contains("international nonproprietary name")
        },
        "medicine names a drug by its generic name"
    )
    report.expect(
        DocumentField.unknown.namingConventions.isEmpty,
        "an unknown field imposes no conventions rather than guessing at some"
    )

    report.begin("names/profile")

    let profile = AgentPrompts.profile(
        from: """
            KIND: an outpatient prescription
            FIELD: medicine and health care
            SUBJECT: a course of treatment for a respiratory infection
            TERM: 处方笺 | prescription form
            """
    )
    report.equal(profile.field, .medicine, "the field is read")
    report.expect(
        profile.guidanceLines().contains { $0.contains("pharmacist") },
        "and the field's conventions reach every stage that sees a block"
    )
    // A model that answered the rest of the form and skipped the field has
    // usually said it anyway.
    let inferred = AgentPrompts.profile(
        from: "KIND: an outpatient prescription\nSUBJECT: a treatment course"
    )
    report.equal(
        inferred.field,
        .medicine,
        "a missing field is inferred from what the document is"
    )
    report.equal(
        AgentPrompts.profile(from: "KIND: a letter to a friend").field,
        .personal,
        "and inference does not stop at the formal documents"
    )

    report.begin("names/parsing")

    let names = AgentPrompts.names(
        from: """
            NAME: 布洛芬 | ibuprofen | its international nonproprietary name
            NAME: 北京协和医院 | Peking Union Medical College Hospital | \
            the hospital's own English name
            NAME: 头孢克肟 | UNKNOWN
            NAME: 阿莫西林 | Amoxilin | spelled out
            NAME: 布洛芬 | Brufen | a brand name
            NAME: | ibuprofen | nothing to look up
            NAME: 感冒
            """,
        language: languages.source
    )
    report.equal(names.count, 2, "only the names the model was sure of")
    report.equal(names.first?.rendering, "ibuprofen", "the rendering is read")
    report.equal(
        names.first?.basis,
        "its international nonproprietary name",
        "and so is what makes it the name"
    )
    report.expect(
        !names.contains { $0.source == "头孢克肟" },
        "UNKNOWN is an answer, and it is not a name"
    )
    // The one entry that is worse than no entry: a name "resolved" to its own
    // Pinyin would suppress the mechanical check in every block it appears
    // in, which is exactly the block where the check was needed.
    report.expect(
        !names.contains { $0.source == "阿莫西林" },
        "a rendering that is only the characters spelled out is dropped"
    )
    report.equal(
        names.filter { $0.source == "布洛芬" }.count,
        1,
        "a name settled twice is settled once"
    )
    report.expect(
        AgentPrompts.names(
            from: AgentPrompts.noNamesMarker,
            language: languages.source
        ).isEmpty,
        "a document with no names in it yields none"
    )
    report.expect(
        AgentPrompts.names(
            from: "I could not read this.",
            language: languages.source
        ).isEmpty,
        "and neither does an answer that ignores the form"
    )
    report.equal(
        AgentPrompts.names(
            from: (1...30)
                .map { "NAME: 药\($0) | drug \($0) | a name" }
                .joined(separator: "\n"),
            language: languages.source,
            limit: 5
        ).count,
        5,
        "the list is capped"
    )

    report.begin("names/reaching the block")

    let prescription = DocumentProfile(
        kind: "an outpatient prescription",
        field: .medicine,
        names: [
            ResolvedName(
                source: "布洛芬",
                rendering: "ibuprofen",
                basis: "its international nonproprietary name"
            ),
            ResolvedName(source: "头孢克肟", rendering: "cefixime")
        ]
    )
    report.equal(
        prescription.names(appearingIn: "布洛芬缓释胶囊，每日两次。").count,
        1,
        "a block is told about the names that are in it"
    )
    report.expect(
        prescription.names(appearingIn: "每日两次，饭后口服。").isEmpty,
        "and about no others"
    )
    report.expect(
        prescription.nameLines(appearingIn: "布洛芬胶囊").first?
            .contains("ibuprofen") == true,
        "the reviewer is told what the document decided the drug is called"
    )

    report.begin("names/spelled out")

    func findings(
        source: String,
        english: String,
        profile: DocumentProfile = .unknown,
        brief: TranslationBrief = .none
    ) -> [IntegrityFinding] {
        TextIntegrity.check(
            source: source,
            translation: english,
            language: languages.source,
            target: languages.target,
            brief: brief,
            profile: profile
        )
        .filter { $0.kind == .transliteratedName }
    }

    let spelled = findings(
        source: "布洛芬缓释胶囊，每日两次。",
        english: "Buluofen sustained-release capsules, twice daily."
    )
    report.equal(spelled.count, 1, "a drug spelled out in Pinyin is caught")
    report.equal(
        spelled.first?.evidence,
        "Buluofen",
        "and the reader is pointed at the word, as printed"
    )
    report.expect(
        spelled.first?.severity == .caution,
        "as something worth a look rather than a failure — some names really "
            + "are their own romanization"
    )
    report.expect(
        findings(
            source: "布洛芬缓释胶囊，每日两次。",
            english: "Ibuprofen sustained-release capsules, twice daily."
        ).isEmpty,
        "the name itself is not"
    )

    // The check has to stay quiet on the case that looks most like it: a
    // private person's name, which has no established English form and is
    // supposed to be transliterated. Written properly it is written in parts,
    // and no window of three characters spells out as one word.
    report.expect(
        findings(
            source: "王小明先生已签署本合同。",
            english: "Mr Wang Xiaoming has signed this contract."
        ).isEmpty,
        "a person's name transliterated in the usual way is left alone"
    )
    report.expect(
        findings(
            source: "本协议于北京签订。",
            english: "This agreement was signed in Beijing."
        ).isEmpty,
        "and so is a place whose English is what it sounds like"
    )

    // What the document already decided outranks the check. An app that
    // flagged a block for using the rendering it was handed would be
    // reporting its own instruction back as a defect.
    report.expect(
        findings(
            source: "阿里巴巴集团的年度报告。",
            english: "The annual report of Alibaba Group.",
            profile: DocumentProfile(
                names: [
                    ResolvedName(
                        source: "阿里巴巴",
                        rendering: "Alibaba",
                        basis: "its registered English name"
                    )
                ]
            )
        ).isEmpty,
        "a name the document settled is not then reported for being itself"
    )
    report.expect(
        findings(
            source: "阿里巴巴集团的年度报告。",
            english: "The annual report of Alibaba Group.",
            brief: TranslationBrief(
                glossary: [
                    GlossaryTerm(
                        term: "阿里巴巴",
                        handling: .render("Alibaba")
                    )
                ]
            )
        ).isEmpty,
        "and neither is one the reader asked for"
    )
    // A block with two of them reports both, and reports each once.
    let both = findings(
        source: "布洛芬和头孢克肟。",
        english: "Buluofen and Toubaokewo."
    )
    report.equal(both.count, 2, "two spelled-out names are two findings")

    report.begin("names/prompts")

    let instructions = AgentPrompts.translationInstructions(
        languages: languages,
        profile: prescription
    )
    report.expect(
        instructions.contains("Pinyin"),
        "the translator is told, by name, what not to do"
    )
    report.expect(
        instructions.contains("generic name"),
        "and what the field expects instead"
    )
    report.expect(
        AgentPrompts.reviewInstructions(
            languages: languages,
            profile: prescription,
            agreedNames: prescription.nameLines(appearingIn: "布洛芬")
        ).contains("ibuprofen"),
        "the reviewer is told what this block's drug is called"
    )
    let lookup = AgentPrompts.nameInstructions(
        languages: languages,
        profile: prescription,
        brief: TranslationBrief(instructions: ["It is my mother's."])
    )
    report.expect(
        lookup.contains("pharmacist"),
        "the lookup is asked in a field rather than in the abstract"
    )
    report.expect(
        lookup.contains("It is my mother's."),
        "and knows what the reader said about the document"
    )
    report.expect(
        lookup.contains(AgentPrompts.unknownName),
        "and is told to say when it does not know"
    )

    await runPrescriptionRun(report)
}

/// The whole chain over a prescription, with a model that answers from a
/// script and a translator that makes the mistake.
private func runPrescriptionRun(_ report: Report) async {
    report.begin("names/prescription")

    let languages = SimplifiedChinese.toEnglish
    let page = [
        "北京协和医院门诊处方笺",
        "患者：王小明，男，四十二岁，临床诊断为急性上呼吸道感染。",
        "布洛芬缓释胶囊，零点三克，每日两次，饭后口服，共七日。",
        "阿莫西林胶囊，零点五克，每日三次，共五日，用药期间多饮水。"
    ]
    // The English a small model produces on a document nobody told it
    // anything about: fluent, correctly dosed, and naming two drugs that do
    // not exist.
    let spelledOut = [
        page[0]: "Beijing Xiehe Hospital outpatient prescription form",
        page[1]: "Patient: Mr Wang Xiaoming, male, forty-two, "
            + "clinically diagnosed with an acute upper respiratory "
            + "tract infection.",
        page[2]: "Buluofen sustained-release capsules, 0.3 g, twice daily, "
            + "taken after meals, for seven days.",
        page[3]: "Amoxilin capsules, 0.5 g, three times daily, for five "
            + "days; drink plenty of water while taking it."
    ]
    let recorder = Recorder()
    let agent = ScriptedAgent { instructions, prompt, _ in
        if instructions.contains("read it and say what it is") {
            return """
                KIND: an outpatient prescription
                FIELD: medicine and health care
                SUBJECT: a course of treatment for a respiratory infection
                """
        }
        if instructions.contains("find the names in it") {
            return """
                NAME: 布洛芬 | ibuprofen | its international nonproprietary name
                NAME: 北京协和医院 | Peking Union Medical College Hospital | \
                the hospital's own English name
                """
        }
        if prompt.contains("Translate this") {
            recorder.append(instructions: instructions, prompt: prompt)
            let source = prompt
                .components(separatedBy: "\n")
                .last?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return spelledOut[source] ?? source
        }
        return AgentPrompts.verdictMarker + " " + AgentPrompts.verdictAccurate
    }

    func reader(_ kind: PageReader) -> ScriptedReader {
        ScriptedReader(
            reader: kind,
            pages: [
                0: page.enumerated().map { index, text in
                    block(text, order: index, y: 0.1 + Double(index) * 0.1)
                }
            ]
        )
    }

    let document = try? await TranslationPipeline(
        languages: languages,
        engines: Engines(
            readers: [reader(.visionOCR), reader(.visionLanguageModel)],
            textAgent: agent,
            preference: .followsInstructions
        )
    ).run(BlankPages(pageCount: 1))

    report.equal(
        document?.profile.field,
        .medicine,
        "the run works out that it is holding a prescription"
    )
    report.equal(
        document?.profile.names.count,
        2,
        "and looks the names in it up before translating a word"
    )

    // The name has to reach the block, which is the only thing that would
    // have prevented the mistake rather than reporting it.
    let drug = recorder.translating(page[2])
    report.expect(
        drug?.prompt.contains("ibuprofen") == true,
        "the block containing the drug is told what the drug is called"
    )
    report.expect(
        drug?.prompt.contains("international nonproprietary name") == true,
        "and why, so the rule reaches the drug on the next line too"
    )
    report.expect(
        recorder.translating(page[3])?.prompt.contains("ibuprofen") != true,
        "and a block without that drug in it is not told about it"
    )

    // And when the mistake is made anyway, it is caught mechanically —
    // including for the drug nobody looked up, which is the case a glossary
    // alone cannot cover.
    let ibuprofen = document?.blocks.first { $0.source.text.contains("布洛芬") }
    report.expect(
        ibuprofen?.findings.contains { $0.kind == .transliteratedName } == true,
        "a drug spelled out in Pinyin is reported"
    )
    report.expect(
        ibuprofen?.confidence.band != .high,
        "and the block does not pass as confident"
    )
    let amoxicillin = document?.blocks.first {
        $0.source.text.contains("阿莫西林")
    }
    report.expect(
        amoxicillin?.findings.contains {
            $0.kind == .transliteratedName
        } == true,
        "including one the lookup never returned"
    )
    report.expect(
        document?.needingAttention.contains {
            $0.source.text.contains("阿莫西林")
        } == true,
        "so it reaches the list of blocks a person has to look at"
    )
}
