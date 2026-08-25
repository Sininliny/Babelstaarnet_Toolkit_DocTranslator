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
/// A user-run model server is the exception rather than the plan. It exists
/// for the two cases the built-in models do not cover — a Mac without Apple
/// Intelligence, and a document a small model reads badly — and it is off
/// until someone turns it on.
@MainActor
public final class EngineDirectory {
    private let ledger: PrivacyLedger
    private let translationEngine = AppleTranslationEngine()
    /// Called whenever the app's own model changes state, so the window can
    /// show a download getting on with itself.
    public var onLocalModelState: (@MainActor (LocalModelStatus) -> Void)?

    #if MLXEngine
    private var store: MLXModelStore?
    #endif

    public init(ledger: PrivacyLedger) {
        self.ledger = ledger
    }

    // MARK: - The app's own model

    /// Built on first use rather than at launch, because building it looks at
    /// the disk and an app should not do that before anyone has asked it for
    /// anything.
    #if MLXEngine
    private func modelStore(_ preferences: Preferences) -> MLXModelStore {
        if let store { return store }
        let model = MLXModelCatalogue.model(id: preferences.localModelID)
        let ledger = self.ledger
        let report = self.onLocalModelState
        let fresh = MLXModelStore(
            model: model,
            onEvent: { state in
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
        store = fresh
        return fresh
    }
    #endif

    public func localModelStatus(
        _ preferences: Preferences
    ) async -> LocalModelStatus {
        #if MLXEngine
        let store = modelStore(preferences)
        let model = await store.model
        return LocalModelStatus(await store.currentState(), model: model)
        #else
        return .notBuiltIn
        #endif
    }

    /// Fetch the weights and load them. Returns when the model is ready to
    /// read a page, or throws with something the reader can act on.
    public func prepareLocalModel(_ preferences: Preferences) async throws {
        #if MLXEngine
        _ = try await modelStore(preferences).prepare()
        #else
        throw LocalModelUnavailable.notBuiltIn
        #endif
    }

    public func removeLocalModel(_ preferences: Preferences) async throws {
        #if MLXEngine
        try await modelStore(preferences).removeFromDisk()
        #endif
    }

    /// Give the memory back between documents.
    public func unloadLocalModel() async {
        #if MLXEngine
        await store?.unload()
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
        let local = modelStore(preferences)
        let localModel = await local.model
        let localAgent = MLXTextAgent(store: local, name: localModel.displayName)
        if preferences.useLocalModel {
            statuses.append(await localAgent.status(for: .pageReader))
            statuses.append(await localAgent.status(for: .adjudicator))
            statuses.append(await localAgent.status(for: .translator))
            statuses.append(await localAgent.status(for: .reviewer))
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

        // The app's own model, where the reader has fetched it. It leads the
        // text roles over Apple's system model for one reason: it is a
        // several-billion-parameter model chosen for Chinese documents, and
        // it is available whether or not Apple Intelligence is.
        #if MLXEngine
        if preferences.useLocalModel {
            let local = modelStore(preferences)
            let localModel = await local.model
            // On disk or already loaded. A model that is still downloading,
            // or that failed, is not a reader — and quietly waiting for a
            // 2 GB download in the middle of someone's first page would look
            // exactly like the app having hung.
            let state = await local.currentState()
            if state == .onDisk || state == .ready {
                readers.removeAll { $0.reader == .visionLanguageModel }
                readers.append(MLXVisionReader(store: local))
                textAgent = MLXTextAgent(
                    store: local,
                    name: localModel.displayName
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

    /// Which of the models on offer are already on this Mac.
    ///
    /// The interface needs this because the choice is otherwise invisible:
    /// three models in a picker look interchangeable, and switching to one
    /// that is not here turns a working app into "the model has not been
    /// downloaded yet" with no hint that the previous choice still is.
    public func downloadedModels() -> Set<String> {
        #if MLXEngine
        let root = MLXModelStore.defaultRoot
        return Set(
            MLXModelCatalogue.all
                .filter { MLXModelStore.isOnDisk($0, root: root) }
                .map(\.id)
        )
        #else
        return []
        #endif
    }

    /// Whether the translation model for this pair is downloaded, which is
    /// the one piece of setup the app can offer to do itself.
    public func translationNeedsDownload(
        for languages: LanguagePair
    ) async -> Bool {
        await translationEngine.availability(for: languages) == .supported
    }
}
