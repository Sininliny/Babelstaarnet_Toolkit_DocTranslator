import DocCore
import Foundation

/// What the app is doing, as it does it.
///
/// Reported rather than inferred. A document takes minutes, and a progress
/// bar that only moves per page tells a reader nothing about whether the app
/// is working or wedged — so every reader that finishes, every disagreement
/// settled, and every block translated is an event.
public enum PipelineEvent: Sendable {
    case started(pages: Int)
    case pageStarted(index: Int, of: Int)
    case readerFinished(PageReader, page: Int, blocks: Int, seconds: Double)
    case pageReconciled(page: Int, blocks: Int, contested: Int)
    case asking(count: Int)
    case readDocument(DocumentProfile)
    case blockTranslated(TranslatedBlock, page: Int, index: Int, of: Int)
    case pageFinished(TranslatedPage)
    case finished(TranslatedDocument)
}

/// Everything the pipeline is allowed to call. Nothing here is constructed by
/// the pipeline itself, which is what lets the whole chain run in a check
/// against fixtures, with no Vision, no model, and no server.
public struct Engines: Sendable {
    /// Which translator leads when both kinds are available.
    public enum TranslatorPreference: String, Sendable, CaseIterable {
        /// The language model, when there is one — it is the only translator
        /// that can follow an instruction.
        case followsInstructions
        /// The dedicated translation model: faster, steadier, deaf to the
        /// brief.
        case fastest
    }

    public var readers: [any PageTranscriber]
    /// The general model, which adjudicates, reviews, asks the clarifying
    /// questions, and translates when it leads.
    public var textAgent: (any TextAgent)?
    /// The dedicated translation engine.
    public var machineTranslator: (any TranslationEngine)?
    public var preference: TranslatorPreference

    public init(
        readers: [any PageTranscriber],
        textAgent: (any TextAgent)? = nil,
        machineTranslator: (any TranslationEngine)? = nil,
        preference: TranslatorPreference = .followsInstructions
    ) {
        self.readers = readers
        self.textAgent = textAgent
        self.machineTranslator = machineTranslator
        self.preference = preference
    }

    public var canTranslate: Bool {
        textAgent != nil || machineTranslator != nil
    }

    /// The reader the survey may spend on pages the document does not carry
    /// text for. The quickest one, and nothing at all if the only reader
    /// available is the slow one: establishing what a document is is worth
    /// half a second a page and is not worth a minute.
    var surveyReader: (any PageTranscriber)? {
        readers.first { $0.reader.readsQuickly }
    }
}

public enum PipelineFailure: LocalizedError {
    case noTranslator
    case noReaders

    public var errorDescription: String? {
        switch self {
        case .noTranslator:
            return """
                No translator is available. Turn on Apple Intelligence, \
                download the Simplified Chinese translation model, or point \
                Laesesalen at a local model server.
                """
        case .noReaders:
            return "No page reader is available."
        }
    }
}

/// Read the page, settle what it says, translate it, check the translation.
public struct TranslationPipeline: Sendable {
    private let languages: LanguagePair
    private let engines: Engines

    public init(languages: LanguagePair, engines: Engines) {
        self.languages = languages
        self.engines = engines
    }

    /// - Parameter clarify: how the app asks its questions. Called at most
    ///   once, after the first page has been read and before anything is
    ///   translated — early enough that the answers apply to the whole
    ///   document, late enough that there is something to ask about. Return
    ///   an empty array to skip.
    public func run(
        _ provider: any PageProvider,
        brief: TranslationBrief = .none,
        clarify: (@Sendable ([ClarificationQuestion]) async -> [SettledQuestion])? = nil,
        onEvent: @Sendable @escaping (PipelineEvent) async -> Void = { _ in }
    ) async throws -> TranslatedDocument {
        guard !engines.readers.isEmpty else { throw PipelineFailure.noReaders }
        guard engines.canTranslate else { throw PipelineFailure.noTranslator }

        let source = provider.source
        await onEvent(.started(pages: source.pageCount))

        let reconciler = Reconciler(
            language: languages.source,
            adjudicator: engines.textAgent
        )

        var brief = brief
        var pages: [TranslatedPage] = []
        var documentContext: String?
        var profile = DocumentProfile.unknown
        // Set on the first page that had anything on it, not on the first
        // page. A document whose cover sheet recognizes as nothing must not
        // spend its one survey on the blank page.
        var surveyed = false
        // Carried across pages as well as within them: a sentence at the top
        // of page four follows the one at the foot of page three, and a
        // translator told otherwise starts the document again twelve times.
        var context = TranslationContext.none
        // The heading the blocks are currently under, in English, carried
        // across page breaks for the same reason. A table that starts on page
        // two has its column headings on page two and its last row on page
        // three, and the row is no less under them for the page turn. Kept in
        // the target language because it is handed to the translator as
        // context, and context in the language being written cannot be
        // mistaken for something to translate.
        var sectionHeading: String?

        for index in 0..<source.pageCount {
            try Task.checkCancellation()
            await onEvent(.pageStarted(index: index, of: source.pageCount))

            let readings = await read(
                page: index,
                from: provider,
                onEvent: onEvent
            )
            let blocks = await reconciler.reconcile(
                readings: readings,
                pageIndex: index
            )
            await onEvent(
                .pageReconciled(
                    page: index,
                    blocks: blocks.count,
                    contested: blocks.filter(\.wasContested).count
                )
            )

            if documentContext == nil {
                documentContext = blocks.first { $0.kind == .heading }?.text
                    ?? blocks.first { $0.kind.isTranslatable }?.text
            }

            // Everything that has to be decided about the document as a
            // whole is decided here: once, on the first page that had
            // anything on it, from a sample taken across the document rather
            // than off the front of it.
            if !surveyed, !blocks.isEmpty, let agent = engines.textAgent {
                surveyed = true
                let sample = await DocumentSurvey(
                    provider: provider,
                    language: languages.source,
                    reader: engines.surveyReader
                ).sample(openingWith: blocks)

                // Read before translated. This is the difference between
                // translating a document and translating a list of sentences
                // that happen to have been printed near each other.
                profile = await DocumentReader(
                    languages: languages,
                    agent: agent
                ).profile(from: sample)
                if !profile.isEmpty {
                    await onEvent(.readDocument(profile))
                }

                // Asked from the same sample, so a question raised only by
                // page nine still gets asked before page one is translated.
                if let clarify {
                    let questions = await ClarificationAgent(
                        languages: languages,
                        agent: agent
                    ).questions(from: sample, profile: profile)
                    if !questions.isEmpty {
                        await onEvent(.asking(count: questions.count))
                        let answers = await clarify(questions)
                        brief.settledQuestions += answers
                        // The one answer the app takes back for itself. The
                        // rest of the brief is guidance for a model; the
                        // field is a value the app's own checks read, and a
                        // reader who has just said "this is a prescription"
                        // should not have to say it again to the stage that
                        // decides what the drug is called.
                        if !profile.field.isKnown,
                           let said = answers.first(
                               where: { $0.question == DocumentField.question }
                           ) {
                            let field = DocumentField(describing: said.answer)
                            if field.isKnown { profile.field = field }
                        }
                    }
                }

                // And the names, last of all: after the profile, so the
                // lookup happens in a field rather than in the abstract, and
                // after the reader has answered, because what they said
                // outranks what the app worked out. See `NameResolver` —
                // this is the stage that keeps a prescription from saying
                // "Buluofen".
                //
                // Checked for cancellation first, because the stage before
                // this one is a dialog: a reader who answered the questions
                // and then changed their mind should not wait out a model
                // call they have already cancelled.
                try Task.checkCancellation()
                let names = await NameResolver(
                    languages: languages,
                    agent: agent
                ).names(from: sample, profile: profile, brief: brief)
                if !names.isEmpty {
                    profile.names = names
                    await onEvent(.readDocument(profile))
                }
            }

            let translator = blockTranslator(
                brief: brief,
                documentContext: documentContext,
                profile: profile
            )
            var translated: [TranslatedBlock] = []
            for (position, block) in blocks.enumerated() {
                try Task.checkCancellation()
                // What is around this block, offered rather than spent: the
                // translator takes the parts this particular block turns out
                // to need. The block after it is only ever the next one on
                // this page — the page after has not been read yet, and
                // reading ahead to give a translator one more sentence would
                // double what a scan costs.
                context.nextSource = blocks[(position + 1)...]
                    .first { $0.kind.isTranslatable }?
                    .text
                context.sectionHeading = sectionHeading
                let result = await translator.translate(
                    block,
                    following: context
                )
                translated.append(result)
                // A heading governs what comes after it, not itself, so this
                // is set once the heading has been translated.
                if block.kind == .heading {
                    sectionHeading = result.text.isEmpty
                        ? block.text
                        : result.text
                }
                if block.kind.isTranslatable {
                    context.previousSource = block.text
                    context.previousTarget = result.text
                }
                await onEvent(
                    .blockTranslated(
                        result,
                        page: index,
                        index: position,
                        of: blocks.count
                    )
                )
            }

            let page = TranslatedPage(index: index, blocks: translated)
            pages.append(page)
            await onEvent(.pageFinished(page))
        }

        let document = TranslatedDocument(
            source: source,
            languages: languages,
            pages: pages,
            engines: record(),
            profile: profile
        )
        await onEvent(.finished(document))
        return document
    }

    /// The readers run together. They are looking at the same page image and
    /// neither needs the other's answer, and on a page where the model takes
    /// twenty seconds the recognizer's half-second is free.
    private func read(
        page index: Int,
        from provider: any PageProvider,
        onEvent: @Sendable @escaping (PipelineEvent) async -> Void
    ) async -> [PageReading] {
        var readings: [PageReading] = []

        if let layer = provider.textLayer(
            at: index,
            language: languages.source
        ) {
            readings.append(layer)
            await onEvent(
                .readerFinished(
                    .pdfTextLayer,
                    page: index,
                    blocks: layer.blocks.count,
                    seconds: 0
                )
            )
        }

        guard let image = try? provider.page(at: index) else {
            return readings
        }

        let readers = engines.readers
        let language = languages.source
        let recognized = await withTaskGroup(
            of: PageReading?.self,
            returning: [PageReading].self
        ) { group in
            for reader in readers {
                group.addTask {
                    try? await reader.transcribe(image, language: language)
                }
            }
            var collected: [PageReading] = []
            for await reading in group {
                guard let reading else { continue }
                collected.append(reading)
                await onEvent(
                    .readerFinished(
                        reading.reader,
                        page: index,
                        blocks: reading.blocks.count,
                        seconds: reading.seconds
                    )
                )
            }
            return collected
        }

        // Order matters downstream: the reconciler picks its primary by
        // authority, and a task group answers in whatever order it finishes.
        return readings + recognized.sorted {
            $0.reader.rawValue < $1.reader.rawValue
        }
    }

    private func blockTranslator(
        brief: TranslationBrief,
        documentContext: String?,
        profile: DocumentProfile
    ) -> BlockTranslator {
        let modelTranslator = engines.textAgent.map {
            TextAgentTranslator(
                agent: $0,
                brief: brief,
                documentContext: documentContext,
                profile: profile
            )
        }

        // A brief the leading translator cannot read is not a brief, and
        // neither is a document profile. When there is anything to follow,
        // the instruction-following translator leads whatever the speed
        // preference says; when there is not, the preference decides.
        let modelLeads = engines.preference == .followsInstructions
            || !brief.isEmpty
            || !profile.isEmpty
        let lead: (any TranslationEngine)?
        let second: (any TranslationEngine)?
        if modelLeads, let modelTranslator {
            lead = modelTranslator
            second = engines.machineTranslator
        } else if let machine = engines.machineTranslator {
            lead = machine
            second = modelTranslator
        } else {
            lead = modelTranslator
            second = nil
        }

        return BlockTranslator(
            languages: languages,
            // Guarded by `canTranslate` before the run starts.
            translator: lead ?? engines.machineTranslator!,
            secondOpinion: second,
            reviewer: engines.textAgent,
            brief: brief,
            profile: profile
        )
    }

    private func record() -> EngineRecord {
        EngineRecord(
            readers: engines.readers.map { $0.reader.displayName },
            adjudicator: engines.textAgent?.engineName,
            translator: engines.textAgent?.engineName
                ?? engines.machineTranslator?.engineName,
            reviewer: engines.textAgent?.engineName
        )
    }
}
