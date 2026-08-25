import DocAgents
import DocAppleModels
import DocCore
import DocModelAPI
import DocOCR
import DocPrivacy
import Foundation

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

    public init(ledger: PrivacyLedger) {
        self.ledger = ledger
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

    /// Whether the translation model for this pair is downloaded, which is
    /// the one piece of setup the app can offer to do itself.
    public func translationNeedsDownload(
        for languages: LanguagePair
    ) async -> Bool {
        await translationEngine.availability(for: languages) == .supported
    }
}
