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
    public var localModelID: String
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
        localModelID: String = "mlx-community/Qwen2.5-VL-3B-Instruct-4bit",
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
