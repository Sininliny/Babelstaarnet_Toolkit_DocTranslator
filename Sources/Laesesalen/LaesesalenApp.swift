import DocCore
import DocRender
import LaesesalenKit
import SwiftUI

/// The app is one window and nothing else.
///
/// No document browser, no library, no history. Læsesalen holds a document
/// for as long as it takes to translate it and forgets it when the window
/// closes: there is no store to leak, no index to search, and nothing on
/// disk afterwards but the export the reader asked for.
struct LaesesalenApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

/// The entry point, with two things in front of the window.
///
/// `Læsesalen.app --engines` prints what each engine reports and exits.
/// "The app says my model is not ready" is otherwise a question nobody can
/// answer without a debugger: the panel shows a state, and the reason it is
/// in that state — which build this is, where it looked, what it found — is
/// exactly what a bug report needs and exactly what a window cannot show.
///
/// `Læsesalen.app --translate <document> [directory]` runs the whole app on
/// one document and writes all three exports, with no window. A fault in how
/// a page is put back together is a fault about one particular page, and the
/// answer to "is it fixed?" is that page, run again, by the same code the
/// window runs. Reaching it through the window means a person doing it, which
/// means it is done once and not again after the next change.
@main
enum Entry {
    static func main() async {
        if let index = CommandLine.arguments.firstIndex(of: "--translate"),
           index + 1 < CommandLine.arguments.count {
            let document = URL(
                fileURLWithPath: CommandLine.arguments[index + 1]
            )
            let directory = index + 2 < CommandLine.arguments.count
                ? URL(fileURLWithPath: CommandLine.arguments[index + 2])
                : document.deletingLastPathComponent()
            await translate(document, into: directory)
            exit(0)
        }
        guard CommandLine.arguments.contains("--engines") else {
            LaesesalenApp.main()
            return
        }
        await report()
        exit(0)
    }

    @MainActor
    private static func translate(_ document: URL, into directory: URL) async {
        let model = AppModel()
        await model.refreshEngines()
        guard model.canTranslate else {
            print("Nothing here can translate. Run --engines to see why.")
            exit(1)
        }
        // Nobody is at the keyboard to answer them, and a run that parks
        // waiting for an answer looks exactly like a run that has hung.
        model.preferences.askClarifyingQuestions = false
        model.open(document)

        var said = ""
        while model.phase.isWorking {
            if model.progress.activity != said {
                said = model.progress.activity
                print(said)
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        if case .failed(let why) = model.phase {
            print("Failed: \(why)")
            exit(1)
        }

        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        for mode in OutputMode.allCases {
            let written = directory.appendingPathComponent(
                model.suggestedFilename(for: mode)
            )
            do {
                try model.export(mode, to: written)
                print("Wrote \(written.path)")
            } catch {
                print("Could not write \(mode.displayName): \(error)")
            }
        }
        let unsure = model.needingAttention.count
        print("\(model.translated.count) blocks, \(unsure) needing a human.")
    }

    @MainActor
    private static func report() async {
        let model = AppModel()
        await model.refreshEngines()
        print("Local model: \(model.localModel.stage)")
        print("            \(model.localModel.explanation)")
        print("Engines:")
        for status in model.statuses {
            let mark: String
            switch status.state {
            case .ready: mark = "ready      "
            case .needsSetup(let why, let remedy):
                mark = "needs setup — \(why) \(remedy)"
            case .unavailable(let why): mark = "unavailable — \(why)"
            }
            print("  [\(status.role.rawValue)] \(status.engineName): \(mark)")
        }
        print("Can translate: \(model.canTranslate)")
    }
}
