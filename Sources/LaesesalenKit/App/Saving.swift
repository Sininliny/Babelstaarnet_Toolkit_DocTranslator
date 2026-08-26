import AppKit
import DocCore
import DocIngest
import DocRender
import Foundation
import UniformTypeIdentifiers

/// The open and save panels.
///
/// This lives on the model rather than in the view it used to live in,
/// because there are two ways to ask for it now — the button in the toolbar
/// and ⌘S in the File menu — and a menu command is not inside the view
/// hierarchy. Two copies of a save panel is how one of them ends up writing
/// the wrong extension.
extension AppModel {

    /// Choosing a document with the panel, rather than dropping one.
    public func openWithPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = DocumentLoader.readableTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Translate"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url)
    }

    /// One of the three modes, saved where the reader says.
    public func save(_ mode: OutputMode) {
        guard document != nil else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [Self.contentType(for: mode)]
        panel.nameFieldStringValue = suggestedFilename(for: mode)
        panel.title = mode.displayName
        panel.prompt = "Save"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try export(mode, to: url)
            exportProblem = nil
        } catch {
            exportProblem = error.localizedDescription
        }
    }

    /// A styled export: the same blocks, arranged for a different reader.
    public func save(style: ExportStyle, as format: StyledFormat) {
        guard let document else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [
            format == .markdown ? .plainText : .html
        ]
        panel.nameFieldStringValue = (
            openDocument?.url.deletingPathExtension().lastPathComponent
                ?? "translation"
        ) + "-en." + format.fileExtension
        panel.title = style.displayName
        panel.prompt = "Save"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = format == .markdown
            ? MarkdownExport.render(document, style: style)
            : HTMLExport.render(document, style: style)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            exportProblem = nil
        } catch {
            // This used to be `try?`, which meant a full disk, a read-only
            // volume or a sandbox refusal all produced a save that silently
            // did nothing and a reader who believed they had the file.
            exportProblem = error.localizedDescription
        }
    }

    public func dismissExportProblem() {
        exportProblem = nil
    }

    static func contentType(for mode: OutputMode) -> UTType {
        switch mode {
        case .sameDocument: return .pdf
        case .plainText: return .plainText
        case .sideBySide: return .html
        }
    }
}
