import Combine
import DocCore
import Foundation
#if MLXEngine
import DocMLX
#endif

/// Where the app's own vision-language model has got to.
///
/// Defined here rather than in `DocMLX` so the interface can be written once.
/// The MLX engine is a build-time option — it needs Xcode's Metal compiler,
/// which the Command Line Tools do not include — and a window full of `#if`
/// is a window nobody can read. This type exists in both builds; only the
/// thing that fills it in is conditional.
public struct LocalModelStatus: Sendable, Equatable {
    public enum Stage: Sendable, Equatable {
        /// This build was made without the engine.
        case notBuiltIn
        case notFetched
        case fetching(Double)
        case loading
        case ready
        case failed(String)
    }

    public var stage: Stage
    /// Which model this is the state of, so a window showing five of them can
    /// tell them apart.
    public var modelID: String
    public var modelName: String
    public var approximateSize: String

    public static let notBuiltIn = LocalModelStatus(
        stage: .notBuiltIn,
        modelID: "",
        modelName: "Local vision model",
        approximateSize: ""
    )

    /// The state of a model this build could run but the reader has not
    /// chosen. Distinct from `notFetched`, which is about a model that *is*
    /// chosen and has not arrived.
    public static let notChosen = LocalModelStatus(
        stage: .notFetched,
        modelID: "",
        modelName: "No separate model",
        approximateSize: ""
    )

    public var isUsable: Bool {
        switch stage {
        case .ready, .loading, .fetching: return true
        default: return false
        }
    }

    public var explanation: String {
        switch stage {
        case .notBuiltIn:
            return """
                This build does not include the local vision model. Building \
                it needs Xcode, which supplies the Metal compiler MLX is \
                written against.
                """
        case .notFetched:
            return "\(modelName) — \(approximateSize), fetched once from "
                + "Hugging Face and run on this Mac from then on."
        case .fetching(let fraction):
            return "Downloading \(modelName) — \(Int(fraction * 100))%."
        case .loading:
            return "Loading \(modelName) into memory."
        case .ready:
            return "\(modelName) is running on this Mac."
        case .failed(let problem):
            return problem
        }
    }
}

#if MLXEngine

extension LocalModelStatus {
    init(_ state: MLXModelState, model: LocalModelSpec) {
        self.modelID = model.id
        self.modelName = model.displayName
        self.approximateSize = model.approximateSize
        switch state {
        case .notFetched: self.stage = .notFetched
        case .fetching(let fraction): self.stage = .fetching(fraction)
        // On disk but not loaded is, to the reader, the same as ready: the
        // app will load it when it is needed and the wait is seconds.
        case .onDisk: self.stage = .ready
        case .loading: self.stage = .loading
        case .ready: self.stage = .ready
        case .failed(let problem): self.stage = .failed(problem)
        }
    }
}

#endif
