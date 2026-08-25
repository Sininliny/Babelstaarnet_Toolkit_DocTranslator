// swift-tools-version: 6.1

import PackageDescription

// Two rules shape this graph, and both are load-bearing.
//
// First, every socket in the app is opened by `DocPrivacy`, and `DocPrivacy`
// can only address loopback. No other target links a networking API, so
// "nothing leaves this Mac" is a property of the dependency graph rather than
// a promise in a README: sending a page somewhere else would take a deliberate
// edit to this file.
//
// Second, no capability target depends on `LanguageChinese`. The agents, the
// OCR, and the renderer are handed a `LanguagePair` value at the call site,
// so adding Japanese or Korean is adding a target beside `LanguageChinese`
// rather than editing the pipeline.
let package = Package(
    name: "Laesesalen",
    // macOS 26, because every default engine in this app is a model that
    // ships with the system: Vision reads the page, the Foundation Models
    // system model adjudicates and reviews, and the Translation framework
    // translates. The version enum in this tools version stops at .v15, so
    // the requirement is written out.
    platforms: [
        .macOS("26.0")
    ],
    // Declared `.static`, and declared at all, so the checks have something to
    // link against on any machine: a library with automatic linkage is free to
    // leave no archive behind, and one toolchain does exactly that.
    products: [
        .executable(name: "Laesesalen", targets: ["Laesesalen"]),
        .library(name: "DocPrivacy", type: .static, targets: ["DocPrivacy"]),
        .library(name: "DocCore", type: .static, targets: ["DocCore"]),
        .library(name: "DocIngest", type: .static, targets: ["DocIngest"]),
        .library(name: "DocOCR", type: .static, targets: ["DocOCR"]),
        .library(
            name: "DocAppleModels",
            type: .static,
            targets: ["DocAppleModels"]
        ),
        .library(
            name: "DocMLX",
            type: .static,
            targets: ["DocMLX"]
        ),
        .library(
            name: "DocModelAPI",
            type: .static,
            targets: ["DocModelAPI"]
        ),
        .library(name: "DocAgents", type: .static, targets: ["DocAgents"]),
        .library(name: "DocRender", type: .static, targets: ["DocRender"]),
        .library(
            name: "LanguageChinese",
            type: .static,
            targets: ["LanguageChinese"]
        ),
        .library(
            name: "LaesesalenKit",
            type: .static,
            targets: ["LaesesalenKit"]
        )
    ],
    // The one external dependency, and the reason for it: MLX is Apple's
    // framework for running models on this machine's own GPU, and
    // mlx-swift-examples is the library that loads and runs published
    // vision-language models with it. It is what lets the app carry its own
    // reader rather than requiring Apple Intelligence to be available or a
    // server to be running.
    traits: [
        Trait(
            name: "MLXEngine",
            description: "Run a vision-language model in this process with MLX."
        )
    ],
    dependencies: [
        .package(
            url: "https://github.com/ml-explore/mlx-swift-examples",
            exact: "2.29.1"
        ),
        // Depended on directly for `HubApi`, which is how the download
        // location is moved out of the reader's Documents folder.
        .package(
            url: "https://github.com/huggingface/swift-transformers",
            exact: "1.0.0"
        )
    ],
    targets: [
        // The only target that knows how to open a connection.
        .target(name: "DocPrivacy", path: "Sources/DocPrivacy"),

        // Pages, blocks, readings, verdicts, and the language-pair seam.
        .target(name: "DocCore", path: "Sources/DocCore"),

        .target(
            name: "DocIngest",
            dependencies: ["DocCore"],
            path: "Sources/DocIngest"
        ),
        .target(
            name: "DocOCR",
            dependencies: ["DocCore"],
            path: "Sources/DocOCR"
        ),
        // The default engines: the models that ship with macOS. This target
        // links no networking API at all, which is what makes the default
        // path incapable of leaving the machine rather than merely unlikely
        // to.
        .target(
            name: "DocAppleModels",
            dependencies: ["DocCore"],
            path: "Sources/DocAppleModels"
        ),
        // The app's own vision-language model, running in this process on
        // this machine's GPU. No Apple Intelligence, no server, no account:
        // the weights are fetched once from Hugging Face and everything after
        // that is local. This is the default second reader.
        .target(
            name: "DocMLX",
            dependencies: [
                "DocCore",
                .product(
                    name: "MLXVLM",
                    package: "mlx-swift-examples",
                    condition: .when(traits: ["MLXEngine"])
                ),
                .product(
                    name: "MLXLLM",
                    package: "mlx-swift-examples",
                    condition: .when(traits: ["MLXEngine"])
                ),
                .product(
                    name: "MLXLMCommon",
                    package: "mlx-swift-examples",
                    condition: .when(traits: ["MLXEngine"])
                ),
                .product(
                    name: "Hub",
                    package: "swift-transformers",
                    condition: .when(traits: ["MLXEngine"])
                )
            ],
            path: "Sources/DocMLX"
        ),
        // The optional backup: a model server the user runs themselves, on
        // this machine. Reaches the network only through DocPrivacy, which
        // can only address loopback.
        .target(
            name: "DocModelAPI",
            dependencies: ["DocCore", "DocPrivacy"],
            path: "Sources/DocModelAPI"
        ),
        // The agents take readers as protocols, so this target does not
        // depend on DocOCR: the pipeline can be run end to end against
        // fixtures with no Vision and no model server involved.
        .target(
            name: "DocAgents",
            dependencies: ["DocCore"],
            path: "Sources/DocAgents"
        ),
        .target(
            name: "DocRender",
            dependencies: ["DocCore"],
            path: "Sources/DocRender"
        ),

        // A language is data conforming to DocCore's shapes. Nothing depends
        // on this but the app.
        .target(
            name: "LanguageChinese",
            dependencies: ["DocCore"],
            path: "Sources/LanguageChinese"
        ),

        // The app: the drop target, the bilingual view, the privacy ledger
        // panel, and the object that composes the capabilities above with a
        // language pair.
        .target(
            name: "LaesesalenKit",
            dependencies: [
                "DocPrivacy",
                "DocCore",
                "DocIngest",
                "DocOCR",
                "DocAppleModels",
                "DocMLX",
                "DocModelAPI",
                "DocAgents",
                "DocRender",
                "LanguageChinese"
            ],
            path: "Sources/LaesesalenKit"
        ),
        .executableTarget(
            name: "Laesesalen",
            dependencies: ["LaesesalenKit"],
            path: "Sources/Laesesalen"
        ),

        // The checks are an executable in the package rather than a test
        // target, because `swift test` cannot run here: the Swift Testing
        // library is a framework that ships with Xcode, and a machine with
        // only the Command Line Tools builds the bundle and then fails to
        // load it. An executable target needs none of that and is run the
        // same way on every machine — `swift run Checks`.
        .executableTarget(
            name: "Checks",
            dependencies: [
                "DocPrivacy",
                "DocCore",
                "DocIngest",
                "DocOCR",
                "DocAgents",
                "DocRender",
                "LanguageChinese",
                .target(name: "DocMLX", condition: .when(traits: ["MLXEngine"]))
            ],
            path: "Tests/Checks"
        )
    ],
    swiftLanguageModes: [.v5]
)
