import Foundation
#if MLXEngine
import DocMLX
#endif

/// Every check, in one binary, run with `swift run Checks`.
///
/// No discovery and no reflection: the list is written out, so a check that
/// was added and never wired up is a visible omission rather than a silent
/// one.
// `swift run Checks --sample <directory>` writes a page and its translated
// copy instead of running the checks, so the layout-preserving export can be
// looked at rather than only asserted about.
if CommandLine.arguments.count > 2, CommandLine.arguments[1] == "--sample" {
    let directory = URL(fileURLWithPath: CommandLine.arguments[2])
    try await Sample.write(to: directory)
    try await SampleForm.write(to: directory)
    exit(0)
}

// What Apple Vision makes of a page, printed rather than asserted. Needs no
// model and no trait: `swift run Checks --ocr-probe`.
if CommandLine.arguments.contains("--ocr-probe") {
    await OCRProbe.run()
    exit(0)
}

// The model checks download weights and need a GPU, so they are asked for
// rather than included: `swift run --traits MLXEngine Checks --local-model`.
#if MLXEngine
if CommandLine.arguments.count > 2,
   CommandLine.arguments[1] == "--full-run" {
    try await FullRun.run(
        writingTo: URL(fileURLWithPath: CommandLine.arguments[2])
    )
    exit(0)
}

if CommandLine.arguments.contains("--model-state") {
    let store = MLXModelStore()
    let model = await store.model
    print("root:      \(MLXModelStore.defaultRoot.path)")
    print("model:     \(model.id)")
    print("on disk:   \(MLXModelStore.isOnDisk(model, root: MLXModelStore.defaultRoot))")
    print("state:     \(await store.currentState())")
    exit(0)
}

if CommandLine.arguments.contains("--vlm-probe") {
    await VLMProbe.run()
    exit(0)
}
#endif

if CommandLine.arguments.contains("--local-model") {
    let report = Report()
    await runLocalModelChecks(report)
    exit(report.summarize())
}

let report = Report()

runPrivacyChecks(report)
runLedgerChecks(report)
runTextIntegrityChecks(report)
runLayoutChecks(report)
runSentenceChecks(report)
runAlignmentChecks(report)
await runReconcilerChecks(report)
runPromptChecks(report)
await runProfileChecks(report)
runConfidenceChecks(report)
runLanguageChecks(report)
runExportChecks(report)
runRenderChecks(report)
await runPipelineChecks(report)
await runEngineChecks(report)
await runOutputModeChecks(report)
runColourChecks(report)

exit(report.summarize())
