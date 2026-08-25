import AppKit
import Combine
import DocCore
import DocRender
import SwiftUI
import UniformTypeIdentifiers

/// The finished document.
struct DocumentView: View {
    @ObservedObject var model: AppModel
    let document: TranslatedDocument
    @StateObject private var state = ViewState()

    final class ViewState: ObservableObject {
        @Published var onlyAttention = false
        @Published var problem: String?
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let problem = state.problem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(Color.orange)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            }
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(visibleBlocks) { block in
                        BlockRow(block: block)
                        Divider()
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(document.source.displayName)
                    .font(.headline)
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Offered as a filter rather than as a separate screen: the
            // blocks that need a person are the app's real output, and they
            // should be one click from the document they came from.
            Toggle(
                "Only what needs a look",
                isOn: $state.onlyAttention
            )
            .toggleStyle(.switch)
            .font(.caption)
            .disabled(document.needingAttention.isEmpty)

            // The mode the reader chose before the run is the button; the
            // rest are a menu behind it. Asking again at the end which of
            // five formats they meant is a question they already answered.
            Button("Save \(model.preferences.mode.displayName.lowercased())…") {
                save(model.preferences.mode)
            }
            .keyboardShortcut("s")

            Menu("Other formats") {
                ForEach(OutputMode.allCases) { mode in
                    Button(mode.displayName + "…") { save(mode) }
                }
                Divider()
                ForEach(ExportStyle.allCases) { style in
                    Menu(style.displayName) {
                        Button("As Markdown…") { export(style, .markdown) }
                        Button("As a web page…") { export(style, .html) }
                    }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Button("New document") { model.reset() }
        }
        .padding(14)
    }

    private var summary: String {
        let attention = document.needingAttention.count
        let total = document.blocks.filter(\.source.kind.isTranslatable).count
        let engines = document.engines.readers.joined(separator: " + ")
        if attention == 0 {
            return "\(total) blocks, read by \(engines). All passed."
        }
        return "\(total) blocks, read by \(engines). "
            + "\(attention) need a human eye."
    }

    private var visibleBlocks: [TranslatedBlock] {
        state.onlyAttention ? document.needingAttention : document.blocks
    }

    private enum Format {
        case markdown
        case html

        var type: UTType { self == .markdown ? .plainText : .html }
        var suffix: String { self == .markdown ? "md" : "html" }
    }

    /// One of the three modes, saved where the reader says.
    private func save(_ mode: OutputMode) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [contentType(for: mode)]
        panel.nameFieldStringValue = model.suggestedFilename(for: mode)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try model.export(mode, to: url)
            state.problem = nil
        } catch {
            state.problem = error.localizedDescription
        }
    }

    private func contentType(for mode: OutputMode) -> UTType {
        switch mode {
        case .sameDocument: return .pdf
        case .plainText: return .plainText
        case .sideBySide: return .html
        }
    }

    private func export(_ style: ExportStyle, _ format: Format) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.type]
        panel.nameFieldStringValue = document.source.url
            .deletingPathExtension()
            .lastPathComponent + "-en." + format.suffix
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let text = format == .markdown
            ? MarkdownExport.render(document, style: style)
            : HTMLExport.render(document, style: style)
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}
