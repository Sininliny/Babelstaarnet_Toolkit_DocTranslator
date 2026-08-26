import DocAgents
import DocModelAPI
import DocRender
import DocPrivacy
import Foundation
import Observation

/// The few things about this app that are a preference rather than a rule.
///
/// Short by design. Where a reader runs their models, whether they want to be
/// asked questions, and which translator leads are genuine choices. Whether a
/// document leaves the Mac is not one, and there is no setting for it.
public struct Preferences: Codable, Equatable, Sendable {
    /// What the reader wants back, remembered between documents.
    public var outputMode: OutputMode.RawValue
    /// Whether to use the app's own vision-language model, where this build
    /// has one and the reader has fetched it. On by default: it is the only
    /// second reader that does not depend on Apple Intelligence being
    /// available on the machine.
    public var useLocalModel: Bool
    /// Which model reads the pages. Empty means "whichever suits this Mac",
    /// which is the default and is resolved from the machine every time it is
    /// asked for rather than written down once — a stored answer would
    /// outlive the machine it was right for, and people move their settings
    /// between Macs.
    public var localModelID: String
    /// A separate model for the text work: adjudicating, translating,
    /// reviewing, reading the document. Empty means the page reader does it
    /// too, which is the ordinary arrangement — a vision-language model is a
    /// language model with an image encoder bolted on, so the text roles cost
    /// nothing extra. A second model is worth its second download and its
    /// second few gigabytes resident only on a Mac that can hold both at
    /// once.
    public var textModelID: String
    public var askClarifyingQuestions: Bool
    public var translatorPreference: Engines.TranslatorPreference.RawValue
    /// Off by default. The app is complete without it.
    public var useLocalServer: Bool
    public var serverHost: String
    public var serverPort: Int
    public var serverDialect: ModelAPIConfiguration.Dialect.RawValue
    public var serverVisionModel: String
    public var serverTextModel: String
    /// Standing instructions applied to every document until changed — house
    /// style, a name that always stays in Chinese, a field's vocabulary.
    public var standingInstructions: [String]

    public init(
        outputMode: String = OutputMode.sameDocument.rawValue,
        useLocalModel: Bool = true,
        localModelID: String = "",
        textModelID: String = "",
        askClarifyingQuestions: Bool = true,
        translatorPreference: String = Engines.TranslatorPreference
            .followsInstructions.rawValue,
        useLocalServer: Bool = false,
        serverHost: String = "127.0.0.1",
        serverPort: Int = 11_434,
        serverDialect: String = ModelAPIConfiguration.Dialect.ollama.rawValue,
        serverVisionModel: String = "qwen2.5vl:7b",
        serverTextModel: String = "qwen3:8b",
        standingInstructions: [String] = []
    ) {
        self.outputMode = outputMode
        self.useLocalModel = useLocalModel
        self.localModelID = localModelID
        self.textModelID = textModelID
        self.askClarifyingQuestions = askClarifyingQuestions
        self.translatorPreference = translatorPreference
        self.useLocalServer = useLocalServer
        self.serverHost = serverHost
        self.serverPort = serverPort
        self.serverDialect = serverDialect
        self.serverVisionModel = serverVisionModel
        self.serverTextModel = serverTextModel
        self.standingInstructions = standingInstructions
    }

    /// Decoding tolerates a preferences file written by a version of the app
    /// that had fewer settings in it. Without this, adding one setting throws
    /// away every setting the reader had.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        func string(_ key: CodingKeys, _ fallback: String) -> String {
            (try? values.decode(String.self, forKey: key)) ?? fallback
        }
        func flag(_ key: CodingKeys, _ fallback: Bool) -> Bool {
            (try? values.decode(Bool.self, forKey: key)) ?? fallback
        }
        let defaults = Preferences()
        self.init(
            outputMode: string(.outputMode, defaults.outputMode),
            useLocalModel: flag(.useLocalModel, defaults.useLocalModel),
            localModelID: string(.localModelID, defaults.localModelID),
            textModelID: string(.textModelID, defaults.textModelID),
            askClarifyingQuestions: flag(
                .askClarifyingQuestions,
                defaults.askClarifyingQuestions
            ),
            translatorPreference: string(
                .translatorPreference,
                defaults.translatorPreference
            ),
            useLocalServer: flag(.useLocalServer, defaults.useLocalServer),
            serverHost: string(.serverHost, defaults.serverHost),
            serverPort: (try? values.decode(Int.self, forKey: .serverPort))
                ?? defaults.serverPort,
            serverDialect: string(.serverDialect, defaults.serverDialect),
            serverVisionModel: string(
                .serverVisionModel,
                defaults.serverVisionModel
            ),
            serverTextModel: string(
                .serverTextModel,
                defaults.serverTextModel
            ),
            standingInstructions: (try? values.decode(
                [String].self,
                forKey: .standingInstructions
            )) ?? defaults.standingInstructions
        )
    }

    public var mode: OutputMode {
        OutputMode(rawValue: outputMode) ?? .sameDocument
    }

    public var preference: Engines.TranslatorPreference {
        Engines.TranslatorPreference(rawValue: translatorPreference)
            ?? .followsInstructions
    }

    public var dialect: ModelAPIConfiguration.Dialect {
        ModelAPIConfiguration.Dialect(rawValue: serverDialect) ?? .ollama
    }

    /// `nil` when the address is not this machine, which is the only way this
    /// can fail: `LoopbackEndpoint` refuses anything else, and the interface
    /// shows the refusal rather than silently falling back to a default.
    public func endpoint() -> Result<LoopbackEndpoint, Error> {
        Result { try LoopbackEndpoint(host: serverHost, port: serverPort) }
    }

    public func modelAPIConfiguration() -> ModelAPIConfiguration? {
        guard useLocalServer, case .success(let endpoint) = endpoint() else {
            return nil
        }
        return ModelAPIConfiguration(
            endpoint: endpoint,
            dialect: dialect,
            visionModel: serverVisionModel.isEmpty ? nil : serverVisionModel,
            textModel: serverTextModel.isEmpty ? nil : serverTextModel
        )
    }

    // MARK: - Persistence

    static let defaultsKey = "dev.sinin.laesesalen.preferences"

    public static func load(
        from defaults: UserDefaults = .standard
    ) -> Preferences {
        guard let data = defaults.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode(
                Preferences.self,
                from: data
              ) else { return Preferences() }
        return decoded
    }

    public func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
