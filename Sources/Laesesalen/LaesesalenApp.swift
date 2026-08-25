import LaesesalenKit
import SwiftUI

/// The app is one window and nothing else.
///
/// No document browser, no library, no history. Læsesalen holds a document
/// for as long as it takes to translate it and forgets it when the window
/// closes: there is no store to leak, no index to search, and nothing on
/// disk afterwards but the export the reader asked for.
@main
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
