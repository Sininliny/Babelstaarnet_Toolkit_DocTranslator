import Foundation

/// What a model is for. The app carries at most two: one that reads pages,
/// and — only where the machine has room to spare — one that does the text
/// work.
public enum LocalModelRole: String, Sendable, Codable, CaseIterable {
    /// Reads the page image. Also does the text work, unless a separate text
    /// model has been chosen.
    case vision
    /// Adjudicating, translating, reviewing, and reading the document.
    case text

    public var displayName: String {
        switch self {
        case .vision: return "Reads pages"
        case .text: return "Text work"
        }
    }
}

/// A model the app can fetch and run on this Mac.
///
/// Described here, in the module that has no idea MLX exists, for two
/// reasons. The window has to list these models in a build made without the
/// MLX engine — that build is the default one, because MLX needs Xcode's
/// Metal compiler — and a list duplicated into the view drifts from the list
/// the app actually loads. And the arithmetic that decides whether a Mac can
/// hold a model is a fact about sizes rather than about MLX, so it belongs
/// where it can be checked without a GPU.
public struct LocalModelSpec: Sendable, Equatable, Identifiable {
    /// The Hugging Face repository. Also the identifier stored in
    /// preferences and the name of the directory the weights land in.
    public let id: String
    public let displayName: String
    public let role: LocalModelRole
    /// Roughly, for the interface to warn with. The real size is whatever the
    /// repository holds.
    public let approximateBytes: Int64
    /// What choosing this one gets you, and what it costs.
    public let note: String
    /// The token this model's chat template accepts to turn its reasoning
    /// off, where it reasons by default.
    ///
    /// A thinking model is the wrong shape for this app and the reason is
    /// arithmetic rather than taste. Every block is a separate call, a long
    /// document is several hundred of them, and a model that reasons for two
    /// hundred tokens before each answer has multiplied the run. Worse, the
    /// reasoning is *output*: left in, a paragraph of the model talking to
    /// itself about how to render 甲方 is what gets drawn onto the page.
    ///
    /// `AgentPrompts.stripReasoning` catches the second problem whatever
    /// happens. This catches the first, when the template honours it.
    public let thinkingSwitch: String?

    public init(
        id: String,
        displayName: String,
        role: LocalModelRole,
        approximateBytes: Int64,
        note: String,
        thinkingSwitch: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.role = role
        self.approximateBytes = approximateBytes
        self.note = note
        self.thinkingSwitch = thinkingSwitch
    }

    /// Whether this model will reason before answering unless it is asked
    /// not to. Worth showing in the interface: it is the difference between
    /// a document that takes ten minutes and one that takes an hour.
    public var reasonsByDefault: Bool { thinkingSwitch != nil }

    public var approximateSize: String {
        ByteCountFormatter.string(
            fromByteCount: approximateBytes,
            countStyle: .file
        )
    }

    /// What holding this model actually costs the machine while it works.
    ///
    /// Not the download size. Weights are the floor; on top of them sit the
    /// key-value cache, the activations, and — for a vision model — a page
    /// image expanded into several thousand tokens, which is the largest
    /// single request this app makes of a model. Two gigabytes of weights
    /// need appreciably more than two gigabytes of memory, and a rule that
    /// pretended otherwise would recommend a model that loads and then
    /// crawls.
    ///
    /// The forty per cent and the three gigabytes are both deliberately
    /// generous. Being wrong in this direction costs the reader a smaller
    /// model than they could have had; being wrong in the other costs them a
    /// machine that swaps for four minutes a page, which does not look like a
    /// bad recommendation — it looks like a broken app.
    public var workingSetBytes: Int64 {
        Int64(Double(approximateBytes) * 1.4) + 3_000_000_000
    }
}

/// The models on offer.
///
/// Short on purpose. Offering forty models makes the choice the reader's
/// problem, and the choice that matters here has one dimension — how much of
/// this Mac you are willing to give it — so the catalogue is one family at
/// four sizes, and the app recommends the size.
///
/// Qwen is the family because of what this app does. Its vision models are
/// trained heavily on Chinese document images, which is exactly the page this
/// app is pointed at; a general-purpose captioning model reads a photograph
/// well and a page of dense 宋体 badly.
public enum LocalModelCatalogue {

    // MARK: - Reading pages

    public static let qwen2VL2B = LocalModelSpec(
        id: "mlx-community/Qwen2-VL-2B-Instruct-4bit",
        displayName: "Qwen2-VL 2B",
        role: .vision,
        approximateBytes: 1_400_000_000,
        note: "The smallest. For an eight-gigabyte Mac, or a tight disk."
    )

    public static let qwen2_5VL3B = LocalModelSpec(
        id: "mlx-community/Qwen2.5-VL-3B-Instruct-4bit",
        displayName: "Qwen2.5-VL 3B",
        role: .vision,
        approximateBytes: 2_300_000_000,
        note: "The balanced choice. Reads dense Chinese pages well."
    )

    public static let qwen3VL4B = LocalModelSpec(
        id: "lmstudio-community/Qwen3-VL-4B-Instruct-MLX-4bit",
        displayName: "Qwen3-VL 4B",
        role: .vision,
        approximateBytes: 2_900_000_000,
        note: "Newer and more accurate than the 3B, and slower."
    )

    public static let qwen2_5VL7B = LocalModelSpec(
        id: "mlx-community/Qwen2.5-VL-7B-Instruct-4bit",
        displayName: "Qwen2.5-VL 7B",
        role: .vision,
        approximateBytes: 4_700_000_000,
        note: "Keeps more of a dense page's figures than the 3B does. "
            + "Wants sixteen gigabytes."
    )

    public static let qwen2_5VL32B = LocalModelSpec(
        id: "mlx-community/Qwen2.5-VL-32B-Instruct-4bit",
        displayName: "Qwen2.5-VL 32B",
        role: .vision,
        approximateBytes: 18_500_000_000,
        note: "The best reader here, on a Mac with the memory for it. "
            + "Minutes a page rather than seconds."
    )

    // MARK: - The text work

    public static let qwen3_4B = LocalModelSpec(
        id: "mlx-community/Qwen3-4B-4bit",
        displayName: "Qwen3 4B",
        role: .text,
        approximateBytes: 2_300_000_000,
        note: "A small text model, for a Mac that cannot hold two large ones.",
        thinkingSwitch: "/no_think"
    )

    public static let qwen2_5_7B = LocalModelSpec(
        id: "mlx-community/Qwen2.5-7B-Instruct-4bit",
        displayName: "Qwen2.5 7B",
        role: .text,
        approximateBytes: 4_300_000_000,
        note: "Translates and reviews better than a vision model of the same "
            + "size, and answers without reasoning first. The usual second "
            + "model."
    )

    public static let qwen3_8B = LocalModelSpec(
        id: "mlx-community/Qwen3-8B-4bit",
        displayName: "Qwen3 8B",
        role: .text,
        approximateBytes: 4_600_000_000,
        note: "Newer and stronger than the Qwen2.5 7B. It reasons before "
            + "answering unless told not to, and Laesesalen tells it not to.",
        thinkingSwitch: "/no_think"
    )

    public static let qwen3_30B_A3B = LocalModelSpec(
        id: "mlx-community/Qwen3-30B-A3B-4bit",
        displayName: "Qwen3 30B",
        role: .text,
        approximateBytes: 17_000_000_000,
        note: "Thirty billion parameters, three billion active at a time — "
            + "large without being slow, on a Mac with the memory.",
        thinkingSwitch: "/no_think"
    )

    public static let visionModels = [
        qwen2VL2B, qwen2_5VL3B, qwen3VL4B, qwen2_5VL7B, qwen2_5VL32B
    ]
    public static let textModels = [
        qwen3_4B, qwen2_5_7B, qwen3_8B, qwen3_30B_A3B
    ]
    public static let all = visionModels + textModels

    /// The model to fall back on when nothing else can be decided: measured
    /// on this app's own fixture page, and the one every number in
    /// `MLXVisionReader` was taken with.
    public static let fallback = qwen2_5VL3B

    public static func model(id: String) -> LocalModelSpec? {
        all.first { $0.id == id }
    }

    public static func models(for role: LocalModelRole) -> [LocalModelSpec] {
        role == .vision ? visionModels : textModels
    }

    // MARK: - What this Mac should run

    /// The largest page reader this machine can hold comfortably.
    ///
    /// Largest, not safest, and that is the point of asking the machine at
    /// all: the 3B was chosen as a default because it runs on a laptop with
    /// other things open, and on a Mac with sixty-four gigabytes that default
    /// is leaving most of the machine idle while a smaller model misreads
    /// figures. The comparison is against `workingSetBytes`, so it accounts
    /// for the page image rather than only for the weights.
    ///
    /// Nothing fits at all on a Mac too small for any of them, and the answer
    /// is still the smallest rather than nothing: `obstacle` says what is in
    /// the way, and an app that answers "no model" to "which model" has told
    /// the reader nothing they can act on.
    public static func largestVisionModel(
        for machine: MachineCapability
    ) -> LocalModelSpec {
        largest(among: visionModels, for: machine) ?? qwen2VL2B
    }

    /// Which page reader to actually use when the reader has not chosen one.
    ///
    /// A model already on the Mac wins over a larger one that is not.
    /// Recommending by size alone reads well until somebody upgrades the app:
    /// the model they have been using for months is suddenly "not in use", the
    /// app wants five gigabytes downloaded before it can read a page, and the
    /// screen that offers to reclaim disk space offers to delete the working
    /// model. What is already here costs nothing and works now, and the
    /// interface still says what this Mac could run — so the larger model is
    /// one press away rather than compulsory.
    public static func recommendedVisionModel(
        for machine: MachineCapability,
        alreadyOnDisk installed: Set<String> = []
    ) -> LocalModelSpec {
        let here = visionModels.filter { installed.contains($0.id) }
        if let best = largest(among: here, for: machine) { return best }
        return largestVisionModel(for: machine)
    }

    /// A separate text model, where the machine can hold one *alongside* the
    /// page reader.
    ///
    /// `nil` is the ordinary answer, and it is not a failure. One model doing
    /// both jobs is the app's default because a vision-language model is a
    /// language model with an image encoder bolted on, so the text roles cost
    /// nothing extra — where a second model is a second download, a second
    /// few gigabytes resident, and two models swapping in and out of memory
    /// on every block. That trade only turns over on a machine with room for
    /// both at once, because a dedicated text model of the same size does
    /// translate and review appreciably better.
    public static func recommendedTextModel(
        for machine: MachineCapability,
        alongside reader: LocalModelSpec
    ) -> LocalModelSpec? {
        largest(
            among: textModels,
            for: machine,
            alsoHolding: reader.workingSetBytes
        )
    }

    /// Whether this Mac can hold both at once, which is the only question
    /// worth asking before offering a second download.
    public static func canHoldBoth(
        _ reader: LocalModelSpec,
        _ text: LocalModelSpec,
        on machine: MachineCapability
    ) -> Bool {
        machine.canHold(
            workingSet: reader.workingSetBytes + text.workingSetBytes
        )
    }

    /// Why a model is not being offered, in words the reader can act on —
    /// or `nil` where it is fine.
    ///
    /// - Parameter alongside: the other model that would be resident at the
    ///   same time. A text model is never held on its own — the page reader
    ///   is in memory too — so asking whether it fits by itself would offer a
    ///   download that cannot be used.
    public static func obstacle(
        to model: LocalModelSpec,
        alongside other: LocalModelSpec? = nil,
        on machine: MachineCapability
    ) -> String? {
        guard machine.isAppleSilicon else {
            return "The app's own models need an Apple-silicon Mac."
        }
        if let other, !canHoldBoth(other, model, on: machine) {
            return "This Mac cannot hold this and \(other.displayName) at "
                + "the same time, and it would have to hold both."
        }
        if !machine.canHold(workingSet: model.workingSetBytes) {
            return "Needs about "
                + ByteCountFormatter.string(
                    fromByteCount: model.workingSetBytes,
                    countStyle: .memory
                )
                + " of memory while it works; this Mac has "
                + machine.memoryDescription + "."
        }
        if !machine.hasRoomOnDisk(for: model.approximateBytes) {
            return "Needs \(model.approximateSize) on disk; "
                + "\(machine.freeDiskDescription) free."
        }
        return nil
    }

    /// Sorted small to large, so "largest that fits" is the last one standing
    /// rather than a comparison written twice.
    private static func largest(
        among models: [LocalModelSpec],
        for machine: MachineCapability,
        alsoHolding other: Int64 = 0
    ) -> LocalModelSpec? {
        models
            .sorted { $0.approximateBytes < $1.approximateBytes }
            .last { machine.canHold(workingSet: $0.workingSetBytes + other) }
    }
}
