#if MLXEngine

import Foundation
import MLXLMCommon
import MLXVLM

/// A model the app can carry.
///
/// Small on purpose. Offering forty models makes the choice the user's
/// problem, and the choice that matters here has one dimension — how much of
/// the disk and the memory you are willing to give it — so the catalogue is
/// three sizes of the same family.
///
/// Qwen is the family because of what this app does. Its vision models are
/// trained heavily on Chinese document images, which is exactly the page this
/// app is pointed at; a general-purpose captioning model reads a photograph
/// well and a page of dense 宋体 badly.
public struct MLXModel: Sendable, Identifiable, Equatable {
    public let id: String
    public let displayName: String
    /// Roughly, for the interface to warn with. The real size is whatever the
    /// repository holds.
    public let approximateBytes: Int64
    public let note: String
    public let configuration: ModelConfiguration

    public static func == (lhs: MLXModel, rhs: MLXModel) -> Bool {
        lhs.id == rhs.id
    }

    public var approximateSize: String {
        ByteCountFormatter.string(
            fromByteCount: approximateBytes,
            countStyle: .file
        )
    }
}

public enum MLXModelCatalogue {
    /// The default. Big enough to read a dense page reliably, small enough to
    /// run on a laptop with other things open.
    public static let qwen2_5VL3B = MLXModel(
        id: "mlx-community/Qwen2.5-VL-3B-Instruct-4bit",
        displayName: "Qwen2.5-VL 3B",
        approximateBytes: 2_300_000_000,
        note: "The balanced choice. Reads dense Chinese pages well.",
        configuration: VLMRegistry.qwen2_5VL3BInstruct4Bit
    )

    public static let qwen3VL4B = MLXModel(
        id: "lmstudio-community/Qwen3-VL-4B-Instruct-MLX-4bit",
        displayName: "Qwen3-VL 4B",
        approximateBytes: 2_900_000_000,
        note: "Newer and more accurate. Slower, and wants more memory.",
        configuration: VLMRegistry.qwen3VL4BInstruct4Bit
    )

    public static let qwen2VL2B = MLXModel(
        id: "mlx-community/Qwen2-VL-2B-Instruct-4bit",
        displayName: "Qwen2-VL 2B",
        approximateBytes: 1_400_000_000,
        note: "The smallest. For an older Mac, or a tight disk.",
        configuration: VLMRegistry.qwen2VL2BInstruct4Bit
    )

    public static let all = [qwen2_5VL3B, qwen3VL4B, qwen2VL2B]
    public static let `default` = qwen2_5VL3B

    public static func model(id: String) -> MLXModel {
        all.first { $0.id == id } ?? `default`
    }
}

#endif
