import DocAgents
import DocCore
import DocIngest
import DocPrivacy
import DocRender
import Foundation
import AppKit
import Combine
import UniformTypeIdentifiers
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
    /// The separate text model, where the reader has chosen one. Its ordinary
    /// state is `notChosen`: one model doing both jobs is the arrangement the
    /// app is built around.
    @Published public private(set) var textModel = LocalModelStatus.notChosen
    @Published public private(set) var localModelProblem: String?
    /// The models already on this Mac, so the picker can say so.
    @Published public private(set) var downloadedModels: Set<String> = []
    /// Everything on this Mac, with what it is taking up — including models
    /// this version of the app no longer offers, which are the ones nothing
    /// else would ever mention again.
    @Published public private(set) var installedModels: [InstalledModel] = []
    /// What this Mac can actually hold, which is what decides how large a
    /// model it is offered. Read afresh on every refresh: free disk changes
    /// between one document and the next.
    @Published public private(set) var machine = MachineCapability.thisMac()
    /// What the app decided the document is, applied to every sentence in it.
    /// Shown because a wrong profile is a wrong translation of everything,
    /// and the reader is the only one who can see that it is wrong.
    @Published public private(set) var profile = DocumentProfile.unknown
    @Published public private(set) var openDocument: DocumentSource?
    /// When the current run began, so the working screen can say how long it
    /// has been going. A reader deciding whether to wait or to go and do
    /// something else is asking a question about elapsed time, and a bar that
    /// has moved a third of the way along does not answer it.
    @Published public private(set) var startedAt: Date?
    /// A save that did not happen, and why. Held here rather than in the
    /// document view because the File menu can start one too.
    @Published public internal(set) var exportProblem: String?

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
        // Wired here rather than at the first refresh. A download reports its
        // progress through these, and a fetch started before anything had
        // refreshed — which is what pressing Get on a freshly opened window
        // does — reported into closures that did not exist yet. The bar sat
        // at nothing for four gigabytes.
        directory.onLocalModelState = { [weak self] status in
            self?.localModel = status
        }
        directory.onTextModelState = { [weak self] status in
            self?.textModel = status
        }
    }

    public func refreshEngines() async {
        machine = directory.machine()
        localModel = await directory.localModelStatus(preferences)
        textModel = await directory.textModelStatus(preferences)
        installedModels = directory.installedModels()
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

    /// The same for the separate text model, where one has been chosen.
    public func fetchTextModel() {
        localModelProblem = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.directory.prepareTextModel(self.preferences)
            } catch {
                self.localModelProblem = error.localizedDescription
            }
            await self.refreshEngines()
        }
    }

    // MARK: - Managing what is on this Mac

    /// Which model reads the pages, and which does the text work. The empty
    /// identifier is meaningful in both: for the reader it means "whichever
    /// suits this Mac", and for the text work it means "the page reader does
    /// it too".
    public var visionModelInUse: LocalModelSpec {
        directory.visionModel(preferences)
    }

    public var textModelInUse: LocalModelSpec? {
        directory.textModel(preferences)
    }

    /// The largest reader this Mac could hold — which is not necessarily the
    /// one in use, because a model already downloaded wins over a larger one
    /// that is not. This is the "you could have better" figure;
    /// `visionModelInUse` is what is actually doing the work.
    public var recommendedVisionModel: LocalModelSpec {
        LocalModelCatalogue.largestVisionModel(for: machine)
    }

    /// The separate text model this Mac has room for beside its page reader,
    /// or `nil` where it has not. `nil` is the ordinary answer.
    public var recommendedTextModel: LocalModelSpec? {
        LocalModelCatalogue.recommendedTextModel(
            for: machine,
            alongside: visionModelInUse
        )
    }

    /// What is in the way of using a model, or `nil` where nothing is.
    ///
    /// A text model is judged beside the page reader rather than on its own,
    /// because it is never resident on its own.
    public func obstacle(to model: LocalModelSpec) -> String? {
        LocalModelCatalogue.obstacle(
            to: model,
            alongside: model.role == .text ? visionModelInUse : nil,
            on: machine
        )
    }

    /// Models on disk that nothing is going to use, and what they are taking.
    public var unusedModels: [InstalledModel] {
        directory.unusedModels(preferences)
    }

    public var unusedModelBytes: Int64 {
        unusedModels.reduce(0) { $0 + $1.bytes }
    }

    /// Whether this build has an engine that could run one of these models
    /// at all.
    ///
    /// MLX is a build-time option — it compiles Metal kernels, and the
    /// `metal` compiler ships with Xcode rather than with the Command Line
    /// Tools — so the app somebody builds without Xcode can list the models,
    /// price them, and delete what an earlier build downloaded, and can do
    /// nothing else with them. A screen that offers to fetch one anyway is
    /// a screen with a button that does nothing.
    public var hasLocalEngine: Bool { localModel.stage != .notBuiltIn }

    /// Choose a model and fetch it, in one press.
    ///
    /// One method rather than `use` followed by `fetch`, and not for
    /// tidiness. The models screen offered "Use this" on a model that was not
    /// here and "Get it" only on the one already chosen, so downloading the
    /// model you wanted took two presses on a row that changed shape between
    /// them — and the first press, which looked exactly like the second,
    /// downloaded nothing. It also raced: `use` started a refresh, a refresh
    /// hands the store a model, and a store handed a model mid-download
    /// resets what it was doing.
    public func get(_ model: LocalModelSpec) {
        switch model.role {
        case .vision: preferences.localModelID = model.id
        case .text: preferences.textModelID = model.id
        }
        localModelProblem = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                switch model.role {
                case .vision:
                    try await self.directory.prepareLocalModel(
                        self.preferences
                    )
                case .text:
                    try await self.directory.prepareTextModel(self.preferences)
                }
            } catch {
                self.localModelProblem = error.localizedDescription
            }
            await self.refreshEngines()
        }
    }

    public func use(visionModel model: LocalModelSpec) {
        preferences.localModelID = model.id
        Task { [weak self] in await self?.refreshEngines() }
    }

    /// Passing `nil` puts the text work back on the page reader, which is
    /// where it lives unless somebody moves it.
    public func use(textModel model: LocalModelSpec?) {
        preferences.textModelID = model?.id ?? ""
        Task { [weak self] in await self?.refreshEngines() }
    }

    /// Give a model's disk space back. An app that can install four gigabytes
    /// and cannot uninstall them is a bad guest.
    public func removeModel(id: String) {
        localModelProblem = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.directory.removeModel(id: id, self.preferences)
            } catch {
                self.localModelProblem = error.localizedDescription
            }
            await self.refreshEngines()
        }
    }

    /// Everything nothing is going to use, in one go.
    public func removeUnusedModels() {
        localModelProblem = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.directory.removeUnusedModels(self.preferences)
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
        startedAt = Date()
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

    /// A page on the clipboard, which is how most single pages arrive.
    ///
    /// Somebody photographs a notice, or screenshots one page of a contract
    /// somebody sent them, and the file they would have to drop does not
    /// exist yet. Making them save it to the Desktop first — and then
    /// remember to delete it — is asking them to leave a copy of the document
    /// lying around, which is the opposite of what this app is for. So a
    /// pasted image is written into the system's temporary directory, opened,
    /// and unlinked as soon as it has been read.
    @discardableResult
    public func openFromPasteboard() -> Bool {
        let pasteboard = NSPasteboard.general
        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], let url = urls.first,
           DocumentLoader.readableTypes.contains(where: { type in
               UTType(filenameExtension: url.pathExtension)?
                   .conforms(to: type) ?? false
           }) {
            open(url)
            return true
        }
        guard let image = NSImage(pasteboard: pasteboard),
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else { return false }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Pasted page.png")
        do {
            try png.write(to: url, options: .atomic)
        } catch {
            phase = .failed(error.localizedDescription)
            return false
        }
        open(url)
        return true
    }

    /// Whether there is anything on the clipboard worth pasting, so the menu
    /// item can be dimmed rather than failing quietly when it is used.
    public var canPaste: Bool {
        let pasteboard = NSPasteboard.general
        if pasteboard.canReadObject(
            forClasses: [NSImage.self],
            options: nil
        ) { return true }
        return pasteboard.canReadObject(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        )
    }

    public func reset() {
        cancel()
        phase = .idle
        translated = []
        progress = JobProgress()
        openDocument = nil
        startedAt = nil
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
            var note = profile.summary.isEmpty
                ? "Read the document"
                : "Read the document: " + profile.summary
            // Reported separately because it happens separately, and after
            // the reader has answered: the same event arrives a second time
            // once the names have been looked up, and saying so is the
            // difference between an app that appears to have stalled and one
            // that is doing the slowest useful thing it does.
            if !profile.names.isEmpty {
                note += " — \(profile.names.count) name"
                    + (profile.names.count == 1 ? "" : "s") + " looked up"
            }
            progress.activity = note
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
