import DocCore
import DocRender
import LaesesalenKit
import SwiftUI

/// The app is one window, a settings window, and nothing else.
///
/// No document browser, no library, no history. Laesesalen holds a document
/// for as long as it takes to translate it and forgets it when the window
/// closes: there is no store to leak, no index to search, and nothing on
/// disk afterwards but the export the reader asked for.
///
/// The model is owned here rather than by the window because three things
/// now need to reach it and only one of them is inside the window: the menu
/// bar, which is a scene of its own, and the settings window, which is
/// another. When `ContentView` owned it, the settings panels could only be
/// sheets over the document — which is what they were, and why they are not
/// any more.
struct LaesesalenApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var window = WindowState()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model, window: window)
        }
        .windowResizability(.contentMinSize)
        .commands {
            LaesesalenCommands(model: model, window: window)
        }

        Settings {
            SettingsView(model: model, window: window)
        }
    }
}

/// The entry point, with two things in front of the window.
///
/// `Laesesalen.app --engines` prints what each engine reports and exits.
/// "The app says my model is not ready" is otherwise a question nobody can
/// answer without a debugger: the panel shows a state, and the reason it is
/// in that state — which build this is, where it looked, what it found — is
/// exactly what a bug report needs and exactly what a window cannot show.
///
/// `Laesesalen.app --models` prints what this Mac can hold, which models are
/// doing the work, and everything downloaded — with `--clean-models` to
/// remove what nothing is using and `--remove-model <id>` to remove one.
/// The models are gigabytes the app installed, and the reader must be able to
/// see and undo that without the window: a build made without the MLX engine
/// cannot download anything and can still be sitting on four gigabytes an
/// earlier build fetched.
///
/// `Laesesalen.app --translate <document> [directory]` runs the whole app on
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
        if let index = CommandLine.arguments.firstIndex(of: "--remove-model"),
           index + 1 < CommandLine.arguments.count {
            await remove(CommandLine.arguments[index + 1])
            exit(0)
        }
        if CommandLine.arguments.contains("--clean-models") {
            await clean()
            exit(0)
        }
        if CommandLine.arguments.contains("--models") {
            await models()
            exit(0)
        }
        guard CommandLine.arguments.contains("--engines") else {
            LaesesalenApp.main()
            return
        }
        await report()
        exit(0)
    }

    // MARK: - The models

    @MainActor
    private static func models() async {
        let model = AppModel()
        await model.refreshEngines()
        print("This Mac:  \(model.machine.summary)")
        let reader = model.visionModelInUse
        var why = " — your choice"
        if model.preferences.localModelID.isEmpty {
            why = model.downloadedModels.contains(reader.id)
                ? " — already on this Mac"
                : " — chosen for this Mac"
        }
        print("Reads pages: \(reader.displayName)"
            + " (\(reader.approximateSize))\(why)")
        if let text = model.textModelInUse {
            print("Text work:   \(text.displayName) (\(text.approximateSize))")
        } else {
            print("Text work:   the same model")
        }
        if reader.id != model.recommendedVisionModel.id {
            print("This Mac could run "
                + "\(model.recommendedVisionModel.displayName).")
        }

        print("\nOn this Mac, in \(LocalModelStorage.defaultRoot.path):")
        if model.installedModels.isEmpty {
            print("  nothing downloaded")
        }
        let spare = Set(model.unusedModels.map(\.id))
        for installed in model.installedModels {
            var note: [String] = []
            if installed.isOrphan { note.append("no longer offered") }
            if !installed.isComplete { note.append("interrupted download") }
            if spare.contains(installed.id) { note.append("not in use") }
            print("  \(installed.id)  \(installed.size)"
                + (note.isEmpty ? "" : "  — " + note.joined(separator: ", ")))
        }
        if !model.unusedModels.isEmpty {
            print("\n--clean-models would free "
                + ByteCountFormatter.string(
                    fromByteCount: model.unusedModelBytes,
                    countStyle: .file
                ) + ".")
        }
    }

    @MainActor
    private static func remove(_ id: String) async {
        let model = AppModel()
        await model.refreshEngines()
        guard model.installedModels.contains(where: { $0.id == id }) else {
            print("\(id) is not on this Mac. Run --models to see what is.")
            exit(1)
        }
        model.removeModel(id: id)
        await settle(until: [id])
        print("Removed \(id).")
    }

    @MainActor
    private static func clean() async {
        let model = AppModel()
        await model.refreshEngines()
        let spare = model.unusedModels
        guard !spare.isEmpty else {
            print("Nothing on this Mac is unused.")
            return
        }
        let freed = ByteCountFormatter.string(
            fromByteCount: model.unusedModelBytes,
            countStyle: .file
        )
        model.removeUnusedModels()
        await settle(until: spare.map(\.id))
        for installed in spare { print("Removed \(installed.id)") }
        print("Freed \(freed).")
    }

    /// A removal runs in a task the model owns, so this waits for the disk
    /// to agree rather than for a timer. Exiting the process mid-delete would
    /// leave a half-removed model, which is the one state the app treats as
    /// an interrupted download and offers to remove again.
    private static func settle(until gone: [String]) async {
        for _ in 0..<200 {
            let present = Set(
                LocalModelStorage
                    .installed(in: LocalModelStorage.defaultRoot)
                    .map(\.id)
            )
            if gone.allSatisfy({ !present.contains($0) }) { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
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
        print("This Mac: \(model.machine.summary)")
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
