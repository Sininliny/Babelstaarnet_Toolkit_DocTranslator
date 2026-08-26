#if MLXEngine

import DocCore
import Foundation
import Hub
import MLXLLM
import MLXLMCommon
import MLXVLM

/// How a model in the app's catalogue is named to MLX.
///
/// All this module contributes is the translation from an identifier the app
/// stores to a configuration MLX loads. Which models exist, how large they
/// are, and whether this Mac can hold one are in `DocCore`, because the build
/// most people run has no MLX in it — MLX needs Xcode's Metal compiler — and
/// that build still has to be able to list the models, say what they would
/// cost, and delete the ones already downloaded.
///
/// `configuration(id:)` returns the registry's own entry where the library
/// knows the repository and a plain configuration where it does not, which is
/// what lets the catalogue name a model the library has never heard of as
/// long as its architecture is one MLX implements.
public enum MLXModelCatalogue {

    public static func configuration(
        for model: LocalModelSpec
    ) -> ModelConfiguration {
        switch model.role {
        case .vision:
            return VLMModelFactory.shared.configuration(id: model.id)
        case .text:
            return LLMModelFactory.shared.configuration(id: model.id)
        }
    }

    /// Load a model with the factory for its kind.
    ///
    /// Explicitly, rather than through `loadModelContainer`, which tries every
    /// registered factory in turn. That convenience is wrong here: the vision
    /// factory is tried first and it *downloads the weights* before it
    /// discovers it cannot build the model, so a text model would arrive by
    /// way of a wasted attempt at reading it as a vision one.
    static func loadContainer(
        _ model: LocalModelSpec,
        hub: HubApi,
        progress: @Sendable @escaping (Progress) -> Void
    ) async throws -> ModelContainer {
        let configuration = configuration(for: model)
        switch model.role {
        case .vision:
            return try await VLMModelFactory.shared.loadContainer(
                hub: hub,
                configuration: configuration,
                progressHandler: progress
            )
        case .text:
            return try await LLMModelFactory.shared.loadContainer(
                hub: hub,
                configuration: configuration,
                progressHandler: progress
            )
        }
    }
}

#endif
