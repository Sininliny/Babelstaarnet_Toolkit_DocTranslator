import DocAgents
import DocCore
import DocIngest
import DocPrivacy
import DocRender
import Foundation
import AppKit
import Combine
import LanguageChinese

/// What the app is doing, as far as the window is concerned.
public enum Phase: Sendable {
    case idle
    case working
    case finished(TranslatedDocument)
    case failed(String)

    public var isWorking: Bool {
        if case .working = self { return true }
        return false
    }
}

/// How far along, in the terms the reader cares about.
public struct JobProgress: Sendable {
    public var pageCount = 0
    public var currentPage = 0
    public var blocksOnPage = 0
    public var blocksDone = 0
    /// One line saying what is happening right now.
    public var activity = ""
    /// What each reader has reported, kept so a slow page does not look like
    /// a hung one.
    public var readerNotes: [String] = []

    public var fraction: Double {
        guard pageCount > 0 else { return 0 }
        let perPage = 1.0 / Double(pageCount)
        let withinPage = blocksOnPage > 0
            ? Double(blocksDone) / Double(blocksOnPage)
            : 0
        return min(1, (Double(currentPage) + withinPage) * perPage)
    }
}

/// The one object the interface talks to.
@MainActor
public final class AppModel: ObservableObject {
    public let ledger: PrivacyLedger
    @Published public private(set) var phase: Phase = .idle
    @Published public private(set) var progress = JobProgress()
    @Published public private(set) var statuses: [EngineStatus] = []
    /// Blocks as they are finished, so the window fills in rather than
    /// waiting.
    @Published public private(set) var translated: [TranslatedBlock] = []
    /// Questions waiting for the reader. Non-empty means the sheet is up and
    /// the pipeline is parked.
    @Published public private(set) var questions: [ClarificationQuestion] = []
    @Published public private(set) var translationNeedsDownload = false
    /// The app's own vision-language model, and how far along it is.
    @Published public private(set) var localModel = LocalModelStatus.notBuiltIn
    @Published public private(set) var localModelProblem: String?
    /// The models already on this Mac, so the picker can say so.
    @Published public private(set) var downloadedModels: Set<String> = []
    /// What the app decided the document is, applied to every sentence in it.
    /// Shown because a wrong profile is a wrong translation of everything,
    /// and the reader is the only one who can see that it is wrong.
    @Published public private(set) var profile = DocumentProfile.unknown
    @Published public private(set) var openDocument: DocumentSource?

    /// What the reader has asked for on this document.
    @Published public var brief = TranslationBrief()
    @Published public var preferences: Preferences {
        didSet { preferences.save() }
    }

    public let languages = SimplifiedChinese.toEnglish
    private let directory: EngineDirectory
    /// Held after the run, because the layout-preserving export draws the
    /// English back onto the pages it came from and needs them again.
    private var pages: (any PageProvider)?
    private var job: Task<Void, Never>?
    private var pendingAnswers: CheckedContinuation<[SettledQuestion], Never>?

    public init() {
        let ledger = PrivacyLedger()
        self.ledger = ledger
        self.directory = EngineDirectory(ledger: ledger)
        self.preferences = Preferences.load()
        self.brief = TranslationBrief(
            instructions: preferences.standingInstructions
        )
    }

    public func refreshEngines() async {
        directory.onLocalModelState = { [weak self] status in
            self?.localModel = status
        }
        localModel = await directory.localModelStatus(preferences)
        downloadedModels = directory.downloadedModels()
        statuses = await directory.statuses(
            languages: languages,
            preferences: preferences
        )
        translationNeedsDownload = await directory.translationNeedsDownload(
            for: languages
        )
    }

    /// True when some engine can read a page and some engine can translate.
    public var canTranslate: Bool {
        statuses.contains { $0.role == .pageReader && $0.state.isReady }
            && statuses.contains {
                ($0.role == .translator || $0.role == .reviewer)
                    && $0.state.isReady
            }
    }

    public var readyEngines: [EngineStatus] {
        statuses.filter { $0.state.isReady }
    }

    public var blockedEngines: [EngineStatus] {
        statuses.filter { !$0.state.isReady }
    }

    // MARK: - The app's own model

    /// Fetch the weights and load them.
    ///
    /// The one moment this app talks to the internet, and it happens because
    /// somebody pressed a button. Nothing of any document is in the request:
    /// it asks a public host for a file by name.
    public func fetchLocalModel() {
        localModelProblem = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.directory.prepareLocalModel(self.preferences)
            } catch {
                self.localModelProblem = error.localizedDescription
            }
            await self.refreshEngines()
        }
    }

    public func removeLocalModel() {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.directory.removeLocalModel(self.preferences)
            } catch {
                self.localModelProblem = error.localizedDescription
            }
            await self.refreshEngines()
        }
    }

    // MARK: - Running a document

    public func open(_ url: URL) {
        cancel()
        translated = []
        progress = JobProgress()
        profile = .unknown
        phase = .working

        job = Task { [weak self] in
            guard let self else { return }
            do {
                let provider = try DocumentLoader.open(url)
                self.pages = provider
                self.openDocument = provider.source
                let engines = await self.directory.engines(
                    languages: self.languages,
                    preferences: self.preferences
                )
                let pipeline = TranslationPipeline(
                    languages: self.languages,
                    engines: engines
                )
                let ask: (@Sendable ([ClarificationQuestion]) async -> [SettledQuestion])?
                if self.preferences.askClarifyingQuestions {
                    ask = { [weak self] questions in
                        await self?.ask(questions) ?? []
                    }
                } else {
                    ask = nil
                }
                let note: @Sendable (PipelineEvent) async -> Void = {
                    [weak self] event in
                    await self?.record(event)
                }
                let document = try await pipeline.run(
                    provider,
                    brief: self.brief,
                    clarify: ask,
                    onEvent: note
                )
                self.phase = .finished(document)
            } catch is CancellationError {
                self.phase = .idle
            } catch {
                self.phase = .failed(error.localizedDescription)
            }
        }
    }

    /// A file dropped on the window. One at a time: a translator that starts
    /// four documents at once finishes none of them any sooner, and the
    /// on-device model is one queue however many callers it has.
    public func open(fromProviders providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            Task { @MainActor [weak self] in self?.open(url) }
        }
        return true
    }

    public func reset() {
        cancel()
        phase = .idle
        translated = []
        progress = JobProgress()
        openDocument = nil
        // And so is the model: a few gigabytes of resident weights that
        // nobody is using is a reason to quit an app rather than leave it
        // open.
        Task { [weak self] in await self?.directory.unloadLocalModel() }
        // The document itself is let go the moment the reader is done with
        // it. Nothing is cached, nothing is written to disk, and there is no
        // recents list to leak what someone translated.
        pages = nil
    }

    public func cancel() {
        job?.cancel()
        job = nil
        // A parked pipeline holds a continuation. Cancelling without
        // resuming it leaks the task and the sheet never closes.
        pendingAnswers?.resume(returning: [])
        pendingAnswers = nil
        questions = []
    }

    private func record(_ event: PipelineEvent) {
        switch event {
        case .started(let pages):
            progress.pageCount = pages
            progress.activity = "Opening \(pages) page"
                + (pages == 1 ? "" : "s")
        case .pageStarted(let index, let of):
            progress.currentPage = index
            progress.blocksDone = 0
            progress.blocksOnPage = 0
            progress.readerNotes = []
            progress.activity = "Reading page \(index + 1) of \(of)"
        case .readerFinished(let reader, _, let blocks, let seconds):
            progress.readerNotes.append(
                "\(reader.displayName): \(blocks) block"
                    + (blocks == 1 ? "" : "s")
                    + String(format: " in %.1fs", seconds)
            )
        case .pageReconciled(_, let blocks, let contested):
            progress.blocksOnPage = blocks
            progress.activity = contested == 0
                ? "The readers agreed on all \(blocks) blocks"
                : "\(contested) of \(blocks) blocks needed settling"
        case .readDocument(let profile):
            self.profile = profile
            progress.activity = profile.summary.isEmpty
                ? "Read the document"
                : "Read the document: " + profile.summary
        case .asking(let count):
            progress.activity = "Asking you \(count) question"
                + (count == 1 ? "" : "s")
        case .blockTranslated(let block, _, let index, let of):
            translated.append(block)
            progress.blocksDone = index + 1
            progress.blocksOnPage = of
            progress.activity = "Translating block \(index + 1) of \(of)"
        case .pageFinished:
            progress.activity = "Page done"
        case .finished:
            progress.activity = "Finished"
        }
    }

    // MARK: - Questions

    private func ask(
        _ questions: [ClarificationQuestion]
    ) async -> [SettledQuestion] {
        await withCheckedContinuation { continuation in
            self.questions = questions
            self.pendingAnswers = continuation
        }
    }

    /// The reader's answers, which become part of the brief for the rest of
    /// the document.
    public func answer(_ answers: [SettledQuestion]) {
        brief.settledQuestions += answers
        questions = []
        pendingAnswers?.resume(returning: answers)
        pendingAnswers = nil
    }

    public func skipQuestions() {
        answer([])
    }

    // MARK: - The brief

    public func addInstruction(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        brief.instructions.append(trimmed)
    }

    public func keepAsWritten(_ term: String, note: String? = nil) {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        brief.glossary.append(
            GlossaryTerm(term: trimmed, handling: .keepAsWritten, note: note)
        )
    }

    public func alwaysRender(_ term: String, as rendering: String) {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = rendering.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !target.isEmpty else { return }
        brief.glossary.append(
            GlossaryTerm(term: trimmed, handling: .render(target))
        )
    }

    public func remove(_ term: GlossaryTerm) {
        brief.glossary.removeAll { $0.id == term.id }
    }

    public func removeInstruction(at index: Int) {
        guard brief.instructions.indices.contains(index) else { return }
        brief.instructions.remove(at: index)
    }

    /// Keep this document's instructions for every document from now on.
    public func makeInstructionsStanding() {
        preferences.standingInstructions = brief.instructions
    }

    // MARK: - Results

    public var document: TranslatedDocument? {
        if case .finished(let document) = phase { return document }
        return nil
    }

    // MARK: - Saving

    public enum ExportFailure: LocalizedError {
        case nothingToExport
        case pagesUnavailable

        public var errorDescription: String? {
            switch self {
            case .nothingToExport:
                return "There is no finished translation to save yet."
            case .pagesUnavailable:
                return """
                    The original pages are no longer open, so the English                     cannot be drawn back onto them. Save the text instead, or                     translate the document again.
                    """
            }
        }
    }

    public func suggestedFilename(for mode: OutputMode) -> String {
        let base = openDocument?.url.deletingPathExtension().lastPathComponent
            ?? "translation"
        return "\(base)-en.\(mode.fileExtension)"
    }

    public func export(_ mode: OutputMode, to url: URL) throws {
        guard let document else { throw ExportFailure.nothingToExport }
        switch mode {
        case .sameDocument:
            guard let pages else { throw ExportFailure.pagesUnavailable }
            let data = try LayoutPreservingPDF.render(document, pages: pages)
            try data.write(to: url, options: .atomic)
        case .plainText:
            try PlainTextExport.render(document)
                .write(to: url, atomically: true, encoding: .utf8)
        case .sideBySide:
            try HTMLExport.render(document, style: .bilingual)
                .write(to: url, atomically: true, encoding: .utf8)
        }
    }

    public var needingAttention: [TranslatedBlock] {
        (document?.blocks ?? translated)
            .filter { $0.confidence.band != .high }
            .sorted { $0.confidence.score < $1.confidence.score }
    }
}
