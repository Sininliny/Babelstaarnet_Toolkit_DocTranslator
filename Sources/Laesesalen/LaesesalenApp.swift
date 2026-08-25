import DocCore
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

/// The entry point, with one thing in front of the window.
///
/// `Læsesalen.app --engines` prints what each engine reports and exits.
/// "The app says my model is not ready" is otherwise a question nobody can
/// answer without a debugger: the panel shows a state, and the reason it is
/// in that state — which build this is, where it looked, what it found — is
/// exactly what a bug report needs and exactly what a window cannot show.
@main
enum Entry {
    static func main() async {
        guard CommandLine.arguments.contains("--engines") else {
            LaesesalenApp.main()
            return
        }
        await report()
        exit(0)
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
