import DocCore
import DocRender
import SwiftUI

/// The menu bar.
///
/// The app had none worth the name: the File menu's New was removed and
/// nothing put in its place, so opening a document could only be done by
/// dropping one or finding a button, saving could only be done from a control
/// in a header that ran out of room, and stopping a run in progress meant
/// hitting a toolbar button. None of that is discoverable and none of it is
/// reachable from the keyboard.
///
/// One shortcut is deliberately not the obvious one. Pasting a page is
/// shift-command-V rather than command-V, because command-V belongs to the
/// text fields in the brief: a menu item claims a key equivalent before the
/// responder chain is consulted, so putting a page-paste on command-V would
/// have quietly broken pasting a sentence into the instructions.
public struct LaesesalenCommands: Commands {
    @ObservedObject private var model: AppModel
    @ObservedObject private var window: WindowState

    public init(model: AppModel, window: WindowState) {
        self.model = model
        self.window = window
    }

    public var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open Document…") { model.openWithPanel() }
                .keyboardShortcut("o")
            Button("Paste a Page") { model.openFromPasteboard() }
                .keyboardShortcut("v", modifiers: [.command, .shift])
            Divider()
            Button("Translate Another") { model.reset() }
                .keyboardShortcut("n")
                .disabled(model.isIdle)
        }

        CommandGroup(replacing: .saveItem) {
            Button(model.preferences.mode.saveTitle) {
                model.save(model.preferences.mode)
            }
            .keyboardShortcut("s")
            .disabled(model.document == nil)

            Menu("Save Another Format") {
                ForEach(OutputMode.allCases) { mode in
                    Button(mode.displayName + "…") { model.save(mode) }
                }
                Divider()
                ForEach(ExportStyle.allCases) { style in
                    Menu(style.displayName) {
                        ForEach(StyledFormat.allCases) { format in
                            Button(format.displayName) {
                                model.save(style: style, as: format)
                            }
                        }
                    }
                }
            }
            .disabled(model.document == nil)
        }

        CommandMenu("Translate") {
            Button("Translation Brief…") { window.showsBrief = true }
                .keyboardShortcut("b")
            Button("Stop") { model.cancel() }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(!model.phase.isWorking)
            Divider()
            Button("What Has Left This Mac…") { window.showsPrivacy = true }
                .keyboardShortcut("l", modifiers: [.command, .shift])
        }
    }
}

extension AppModel {
    /// Whether there is nothing to go back from, which is what decides
    /// whether "Translate Another" means anything.
    var isIdle: Bool {
        if case .idle = phase { return true }
        return false
    }
}
