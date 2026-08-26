import DocAgents
import DocAppleModels
import DocCore
import DocModelAPI
import DocOCR
import DocPrivacy
import Foundation
#if MLXEngine
import DocMLX
#endif

/// What is available to do the work, and what it would take to have more.
///
/// The app's default configuration is every engine that came with macOS and
/// nothing else: Vision reads the page, the system model reads it a second
/// time and settles the disagreements, and either the system model or the
/// Translation framework does the translating. Nothing is downloaded, nothing
/// is installed, and nothing is configured.
///
/// Above that sit the app's own models, which are the only engines here that
/// do not depend on what Apple has decided this Mac is eligible for. There
/// are at most two: one that reads pages, and — on a Mac with the memory for
/// both at once — a second that does the text work. Which ones, and whether
/// the second exists at all, is decided from the machine rather than fixed,
/// because the same default is wrong on an eight-gigabyte laptop and on a Mac
/// with sixty-four.
///
/// A user-run model server is the exception rather than the plan. It exists
/// for the two cases the built-in models do not cover — a Mac without Apple
/// Intelligence, and a document a small model reads badly — and it is off
/// until someone turns it on.
@MainActor
public final class EngineDirectory {
    private let ledger: PrivacyLedger
    private let translationEngine = AppleTranslationEngine()
    /// Called whenever one of the app's own models changes state, so the
    /// window can show a download getting on with itself.
    public var onLocalModelState: (@MainActor (LocalModelStatus) -> Void)?
    public var onTextModelState: (@MainActor (LocalModelStatus) -> Void)?

    #if MLXEngine
    /// The stores, once they have been built. Named apart from the methods
    /// that build them because a property and a method of the same name
    /// compile and do not read.
    private var builtVisionStore: MLXModelStore?
    private var builtTextStore: MLXModelStore?
    #endif

    public init(ledger: PrivacyLedger) {
        self.ledger = ledger
    }

    // MARK: - This Mac

    /// Read afresh rather than remembered. Free disk is different between one
    /// document and the next, and a recommendation made from a stale reading
    /// is a download that fails half way.
    public func machine() -> MachineCapability {
        MachineCapability.thisMac(diskAt: LocalModelStorage.defaultRoot)
    }

    /// Which model reads the pages: the reader's choice where they have made
    /// one, and otherwise the largest this Mac can hold comfortably.
    public func visionModel(_ preferences: Preferences) -> LocalModelSpec {
        if let chosen = LocalModelCatalogue.model(id: preferences.localModelID),
           chosen.role == .vision {
            return chosen
        }
        return LocalModelCatalogue.recommendedVisionModel(
            for: machine(),
            alreadyOnDisk: downloadedModels()
        )
    }

    /// The separate text model, where the reader has chosen one. `nil` — the
    /// page reader does the text work too — is the ordinary answer and not a
    /// failure.
    public func textModel(_ preferences: Preferences) -> LocalModelSpec? {
        guard let chosen = LocalModelCatalogue.model(id: preferences.textModelID),
              chosen.role == .text else { return nil }
        return chosen
    }

    // MARK: - The app's own models

    /// Built on first use rather than at launch, because building it looks at
    /// the disk and an app should not do that before anyone has asked it for
    /// anything.
    #if MLXEngine
    private func store(
        for model: LocalModelSpec,
        existing: MLXModelStore?,
        report: (@MainActor (LocalModelStatus) -> Void)?
    ) async -> MLXModelStore {
        let ledger = self.ledger
        if let existing {
            // The reader may have changed their mind since it was built. A
            // store told to hold a different model drops the one it had.
            await existing.use(model)
            return existing
        }
        return MLXModelStore(
            model: model,
            onEvent: { state, model in
                Task { @MainActor in
                    report?(LocalModelStatus(state, model: model))
                }
            },
            onFetch: { fetch in
                // Only the completed download is written down. Progress
                // arrives hundreds of times and a ledger nobody can scroll
                // is not evidence of anything.
                guard fetch.finished else { return }
                Task { @MainActor in
                    ledger.recordModelDownload(
                        host: fetch.host,
                        model: fetch.model,
                        bytesReceived: Int(fetch.bytesReceived)
                    )
                }
            }
        )
    }

    private func visionStore(
        _ preferences: Preferences
    ) async -> MLXModelStore {
        let fresh = await store(
            for: visionModel(preferences),
            existing: builtVisionStore,
            report: onLocalModelState
        )
        builtVisionStore = fresh
        return fresh
    }

    /// `nil` where no separate text model is configured, which is the usual
    /// case: the page reader answers the text questions as well.
    private func textStore(
        _ preferences: Preferences
    ) async -> MLXModelStore? {
        guard let model = textModel(preferences) else {
            // Dropping the reference is what gives the memory back: the
            // container goes with it.
            builtTextStore = nil
            return nil
        }
        let fresh = await store(
            for: model,
            existing: builtTextStore,
            report: onTextModelState
        )
        builtTextStore = fresh
        return fresh
    }
    #endif

    public func localModelStatus(
        _ preferences: Preferences
    ) async -> LocalModelStatus {
        #if MLXEngine
        let store = await visionStore(preferences)
        return LocalModelStatus(
            await store.currentState(),
            model: await store.model
        )
        #else
        return .notBuiltIn
        #endif
    }

    public func textModelStatus(
        _ preferences: Preferences
    ) async -> LocalModelStatus {
        #if MLXEngine
        guard let store = await textStore(preferences) else { return .notChosen }
        return LocalModelStatus(
            await store.currentState(),
            model: await store.model
        )
        #else
        return .notBuiltIn
        #endif
    }

    /// Fetch the weights and load them. Returns when the model is ready to
    /// read a page, or throws with something the reader can act on.
    public func prepareLocalModel(_ preferences: Preferences) async throws {
        #if MLXEngine
        _ = try await visionStore(preferences).prepare()
        #else
        throw LocalModelUnavailable.notBuiltIn
        #endif
    }

    public func prepareTextModel(_ preferences: Preferences) async throws {
        #if MLXEngine
        guard let store = await textStore(preferences) else { return }
        _ = try await store.prepare()
        #else
        throw LocalModelUnavailable.notBuiltIn
        #endif
    }

    /// Delete one model's weights, whichever store — if any — is holding it.
    @discardableResult
    public func removeModel(
        id: String,
        _ preferences: Preferences
    ) async throws -> Int64 {
        #if MLXEngine
        // Through the stores rather than around them: the model being deleted
        // may be one that is loaded, and deleting the weights out from under
        // a live container leaves an app that works until the next launch.
        let freed = try await visionStore(preferences).remove(id: id)
        if let text = await textStore(preferences) {
            _ = try? await text.remove(id: id)
        }
        return freed
        #else
        return try LocalModelStorage.remove(id, in: LocalModelStorage.defaultRoot)
        #endif
    }

    /// Everything on this Mac that nothing is going to use, removed.
    ///
    /// Two kinds, and the second is the one that would otherwise never be
    /// mentioned again: a model the reader tried and moved on from, and one a
    /// previous version of the app downloaded and this one no longer offers
    /// at all.
    @discardableResult
    public func removeUnusedModels(
        _ preferences: Preferences
    ) async throws -> Int64 {
        var freed: Int64 = 0
        for model in unusedModels(preferences) {
            freed += (try? await removeModel(id: model.id, preferences)) ?? 0
        }
        return freed
    }

    public func unusedModels(_ preferences: Preferences) -> [InstalledModel] {
        var inUse: Set<String> = [visionModel(preferences).id]
        if let text = textModel(preferences) { inUse.insert(text.id) }
        return LocalModelStorage.unused(
            keeping: inUse,
            in: LocalModelStorage.defaultRoot
        )
    }

    /// Give the memory back between documents.
    public func unloadLocalModel() async {
        #if MLXEngine
        await builtVisionStore?.unload()
        await builtTextStore?.unload()
        #endif
    }

    public enum LocalModelUnavailable: LocalizedError {
        case notBuiltIn

        public var errorDescription: String? {
            LocalModelStatus.notBuiltIn.explanation
        }
    }

    /// Every engine the app could use, ready or not, with the reason and the
    /// remedy where it is not.
    public func statuses(
        languages: LanguagePair,
        preferences: Preferences
    ) async -> [EngineStatus] {
        var statuses: [EngineStatus] = [
            EngineStatus(
                engineName: "Apple Vision",
                role: .pageReader,
                // Part of macOS, no download, no permission, always there.
                state: .ready,
                isBuiltIn: true
            )
        ]

        if #available(macOS 27.0, *) {
            statuses.append(SystemVisionReader().status())
        } else {
            statuses.append(
                EngineStatus(
                    engineName: "Apple on-device model (vision)",
                    role: .pageReader,
                    state: .unavailable(
                        "Reading pages with the system model needs macOS 27."
                    ),
                    isBuiltIn: true
                )
            )
        }

        #if MLXEngine
        if preferences.useLocalModel {
            let vision = await visionStore(preferences)
            let visionModel = await vision.model
            let visionAgent = MLXTextAgent(
                store: vision,
                name: visionModel.displayName
            )
            statuses.append(await visionAgent.status(for: .pageReader))

            // The text roles go to the separate model where there is one, and
            // to the page reader where there is not. Only one of the two is
            // listed for each role: a screen that names two engines for the
            // same job is a screen that cannot say which one did it.
            if let text = await textStore(preferences) {
                let textModel = await text.model
                let textAgent = MLXTextAgent(
                    store: text,
                    name: textModel.displayName
                )
                statuses.append(await textAgent.status(for: .adjudicator))
                statuses.append(await textAgent.status(for: .translator))
                statuses.append(await textAgent.status(for: .reviewer))
            } else {
                statuses.append(await visionAgent.status(for: .adjudicator))
                statuses.append(await visionAgent.status(for: .translator))
                statuses.append(await visionAgent.status(for: .reviewer))
            }
        }
        #endif

        let systemAgent = SystemTextAgent()
        statuses.append(await systemAgent.status(for: .adjudicator))
        statuses.append(await systemAgent.status(for: .reviewer))
        statuses.append(await translationEngine.status(for: languages))

        if let configuration = preferences.modelAPIConfiguration() {
            let client = await ModelAPIClient(
                configuration: configuration,
                ledger: ledger
            )
            if let model = configuration.textModel {
                statuses.append(
                    await ModelAPITextAgent(
                        client: client,
                        model: model,
                        dialect: configuration.dialect
                    ).status(for: .translator)
                )
            }
        } else if preferences.useLocalServer,
                  case .failure(let error) = preferences.endpoint() {
            statuses.append(
                EngineStatus(
                    engineName: "Local model server",
                    role: .translator,
                    state: .unavailable(error.localizedDescription),
                    isBuiltIn: false
                )
            )
        }

        return statuses
    }

    /// The engines to actually run with.
    public func engines(
        languages: LanguagePair,
        preferences: Preferences
    ) async -> Engines {
        var readers: [any PageTranscriber] = [VisionTranscriber()]
        var textAgent: (any TextAgent)?
        var machineTranslator: (any TranslationEngine)?

        if #available(macOS 27.0, *), SystemVisionReader.isAvailable() {
            readers.append(SystemVisionReader())
        }

        let systemAgent = SystemTextAgent()
        if await systemAgent.status(for: .translator).state.isReady,
           systemAgent.supports(languages) {
            textAgent = systemAgent
        }

        // The app's own models, where the reader has fetched them. They lead
        // the text roles over Apple's system model for one reason: they are
        // several-billion-parameter models chosen for Chinese documents, and
        // they are available whether or not Apple Intelligence is.
        #if MLXEngine
        if preferences.useLocalModel {
            let vision = await visionStore(preferences)
            let visionModel = await vision.model
            // On disk or already loaded. A model that is still downloading,
            // or that failed, is not a reader — and quietly waiting for a
            // multi-gigabyte download in the middle of someone's first page
            // would look exactly like the app having hung.
            if await vision.isUsable {
                readers.removeAll { $0.reader == .visionLanguageModel }
                readers.append(MLXVisionReader(store: vision))
                textAgent = MLXTextAgent(
                    store: vision,
                    name: visionModel.displayName
                )
            }
            // A separate text model supersedes it in the text roles. It only
            // exists on a Mac that can hold both at once, which is what makes
            // it worth two sets of resident weights: a dedicated text model
            // translates and reviews appreciably better than a vision model
            // of the same size.
            if let text = await textStore(preferences), await text.isUsable {
                textAgent = MLXTextAgent(
                    store: text,
                    name: await text.model.displayName
                )
            }
        }
        #endif

        if await translationEngine.status(for: languages).state.isReady {
            machineTranslator = translationEngine
        }

        // The server, where the reader has one. It supersedes the system
        // model in the text roles rather than joining it: two general models
        // adjudicating would double the calls to settle the same question.
        if let configuration = preferences.modelAPIConfiguration() {
            let client = await ModelAPIClient(
                configuration: configuration,
                ledger: ledger
            )
            if let model = configuration.textModel {
                let agent = ModelAPITextAgent(
                    client: client,
                    model: model,
                    dialect: configuration.dialect
                )
                if await agent.status(for: .translator).state.isReady {
                    textAgent = agent
                }
            }
            if let model = configuration.visionModel {
                let reader = ModelAPIVisionReader(
                    client: client,
                    model: model,
                    dialect: configuration.dialect
                )
                // Added rather than substituted: a stronger vision model is
                // a better second reader, and the built-in one still reads
                // the page for free.
                readers.removeAll { $0.reader == .visionLanguageModel }
                readers.append(reader)
            }
        }

        return Engines(
            readers: readers,
            textAgent: textAgent,
            machineTranslator: machineTranslator,
            preference: preferences.preference
        )
    }

    /// Which of the models on offer are already on this Mac, and how much of
    /// the disk they are taking.
    ///
    /// The interface needs this because the choice is otherwise invisible:
    /// five models in a list look interchangeable, and switching to one that
    /// is not here turns a working app into "the model has not been
    /// downloaded yet" with no hint that the previous choice still is.
    public func installedModels() -> [InstalledModel] {
        LocalModelStorage.installed(in: LocalModelStorage.defaultRoot)
    }

    public func downloadedModels() -> Set<String> {
        Set(installedModels().filter(\.isComplete).map(\.id))
    }

    /// Whether the translation model for this pair is downloaded, which is
    /// the one piece of setup the app can offer to do itself.
    public func translationNeedsDownload(
        for languages: LanguagePair
    ) async -> Bool {
        await translationEngine.availability(for: languages) == .supported
    }
}
