import DocCore
import DocPrivacy
import Foundation

/// A model server the user runs themselves.
///
/// Everything the app does by default is done by a model that came with
/// macOS. This is the other path, for two situations the built-in models do
/// not cover: a Mac where Apple Intelligence is unavailable, and a document
/// where a 3-billion-parameter system model is not enough — a dense legal
/// contract, a medical report, a technical standard. A 30B model on the same
/// machine will read those better, and someone who has one running should be
/// able to point the app at it.
///
/// What does not change is where it runs. The endpoint is a
/// `LoopbackEndpoint`, so "point it at my server" cannot become "point it at
/// a server". Making this configurable at all is the only reason `DocPrivacy`
/// exists in the shape it does.
public struct ModelAPIConfiguration: Sendable, Equatable {
    /// Which wire format the server speaks. Both are spoken by everything
    /// people actually run locally; between them they cover Ollama,
    /// llama.cpp's server, LM Studio, and vLLM.
    public enum Dialect: String, Sendable, CaseIterable, Identifiable {
        case ollama
        case openAICompatible

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .ollama: return "Ollama"
            case .openAICompatible: return "OpenAI-compatible"
            }
        }

        public var defaultPort: Int {
            switch self {
            case .ollama: return 11_434
            case .openAICompatible: return 8_080
            }
        }

        var chatPath: String {
            switch self {
            case .ollama: return "/api/chat"
            case .openAICompatible: return "/v1/chat/completions"
            }
        }

        var listPath: String {
            switch self {
            case .ollama: return "/api/tags"
            case .openAICompatible: return "/v1/models"
            }
        }
    }

    public let endpoint: LoopbackEndpoint
    public let dialect: Dialect
    /// The model asked to read pages. Must be able to see images.
    public let visionModel: String?
    /// The model asked to adjudicate, translate, and review.
    public let textModel: String?

    public init(
        endpoint: LoopbackEndpoint,
        dialect: Dialect,
        visionModel: String? = nil,
        textModel: String? = nil
    ) {
        self.endpoint = endpoint
        self.dialect = dialect
        self.visionModel = visionModel
        self.textModel = textModel
    }

    /// What a first-time user most likely has: Ollama on its default port,
    /// with a Qwen pair — the models that read Chinese best at sizes that fit
    /// on a laptop.
    public static func ollamaDefault() -> ModelAPIConfiguration {
        ModelAPIConfiguration(
            endpoint: .ollama,
            dialect: .ollama,
            visionModel: "qwen2.5vl:7b",
            textModel: "qwen3:8b"
        )
    }
}
