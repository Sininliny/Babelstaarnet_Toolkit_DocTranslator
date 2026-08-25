import Foundation

/// Every check, in one binary, run with `swift run Checks`.
///
/// No discovery and no reflection: the list is written out, so a check that
/// was added and never wired up is a visible omission rather than a silent
/// one.
// `swift run Checks --sample <directory>` writes a page and its translated
// copy instead of running the checks, so the layout-preserving export can be
// looked at rather than only asserted about.
if CommandLine.arguments.count > 2, CommandLine.arguments[1] == "--sample" {
    try await Sample.write(
        to: URL(fileURLWithPath: CommandLine.arguments[2])
    )
    exit(0)
}

let report = Report()

runPrivacyChecks(report)
runTextIntegrityChecks(report)
runLayoutChecks(report)
runAlignmentChecks(report)
await runReconcilerChecks(report)
runPromptChecks(report)
runConfidenceChecks(report)
runLanguageChecks(report)
runExportChecks(report)
await runPipelineChecks(report)
await runEngineChecks(report)
await runOutputModeChecks(report)
runColourChecks(report)

exit(report.summarize())
