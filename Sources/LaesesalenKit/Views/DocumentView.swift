import AppKit
import Combine
import DocCore
import DocRender
import SwiftUI
import UniformTypeIdentifiers

/// The finished document.
///
/// The header used to be one `HStack` holding the filename, a summary, the
/// profile, a switch, a save button, a menu and a "New document" button, at a
/// minimum window width of 760 points. It did not fit, and the save button was
/// built by lowercasing the mode's name, so the widest control on the screen
/// read "Save the same document, in english…".
///
/// Actions belong in the toolbar, which is the one part of a Mac window that
/// is built to run out of room gracefully. What is left here is information:
/// what this document is, what the app made of it, and — where there is one —
/// the strip that matters more than any of it, which is the count of blocks a
/// person still has to look at and the means to walk through them.
struct DocumentView: View {
    @ObservedObject var model: AppModel
    let document: TranslatedDocument
    @StateObject private var state = ViewState()
    @StateObject private var layout = LayoutState()

    final class ViewState: ObservableObject {
        @Published var onlyAttention = false
        @Published var query = ""
        /// Which flagged block the reader is standing on, for the two arrows
        /// that step between them. Negative until they have used one, so the
        /// first press of the down arrow goes to the first flagged block
        /// rather than to the second.
        @Published var cursor = -1
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let problem = model.exportProblem { problemBar(problem) }
            Divider()
            blocks
        }
        .searchable(
            text: $state.query,
            placement: .toolbar,
            prompt: "Find in this document"
        )
        .toolbar { toolbar }
    }

    // MARK: - What this document is

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(document.source.displayName)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Badge(document.source.kind.displayName)
                Badge(
                    "\(document.source.pageCount) "
                        + (document.source.pageCount == 1 ? "page" : "pages")
                )
                Spacer(minLength: 0)
            }

            Text(summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !document.profile.summary.isEmpty {
                Label(
                    "Translated as " + document.profile.summary,
                    systemImage: "text.book.closed"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            if !document.needingAttention.isEmpty { attentionStrip }
        }
        .padding(Metrics.rowInset)
    }

    /// The blocks that need a person are the app's real output, so they get
    /// the one piece of chrome on this screen that looks like something.
    ///
    /// It used to be a switch labelled "Only what needs a look", off to the
    /// right of the header, with no count on it — so the number the reader
    /// most wants was in a sentence two lines above, and there was no way at
    /// all to move from one flagged block to the next in a forty-page
    /// document except to scroll and look for orange.
    private var attentionStrip: some View {
        HStack(spacing: 10) {
            Image(systemName: "flag.fill")
                .foregroundStyle(.orange)
            Text(
                "\(document.needingAttention.count) of "
                    + "\(translatableCount) blocks need a human eye"
            )
            .font(.callout.weight(.medium))

            Spacer(minLength: 8)

            Button {
                step(-1)
            } label: {
                Image(systemName: "chevron.up")
            }
            .help("Previous block needing a look")
            .accessibilityLabel("Previous block needing a look")

            Button {
                step(1)
            } label: {
                Image(systemName: "chevron.down")
            }
            .help("Next block needing a look")
            .accessibilityLabel("Next block needing a look")

            Toggle("Only these", isOn: $state.onlyAttention)
                .toggleStyle(.button)
                .help("Hide every block that passed")
        }
        .controlSize(.small)
        .card(padding: 10, tint: .orange)
    }

    private func problemBar(_ problem: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(problem)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Dismiss") { model.dismissExportProblem() }
                .controlSize(.small)
        }
        .padding(.horizontal, Metrics.rowInset)
        .padding(.bottom, 8)
    }

    // MARK: - The blocks

    private var blocks: some View {
        ScrollViewReader { scroller in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    if visibleBlocks.isEmpty { nothingFound }
                    ForEach(pages, id: \.index) { page in
                        Section {
                            ForEach(page.blocks) { block in
                                BlockRow(
                                    block: block,
                                    mode: model.preferences.mode,
                                    isNarrow: layout.isNarrow
                                )
                                .id(block.id)
                                Divider()
                            }
                        } header: {
                            pageHeader(page.index)
                        }
                    }
                }
            }
            .measuringWidth(into: layout)
            .onChange(of: state.cursor) {
                guard let target = target else { return }
                withAnimation(.smooth(duration: 0.25)) {
                    scroller.scrollTo(target, anchor: .center)
                }
            }
        }
    }

    /// A page break, which the list had no notion of at all: forty pages
    /// arrived as one uninterrupted column, and a reader who found a bad
    /// block had no way to say which page of the original to go and look at.
    private func pageHeader(_ index: Int) -> some View {
        HStack(spacing: 8) {
            Text("Page \(index + 1)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Rectangle()
                .fill(Color.secondary.opacity(0.2))
                .frame(height: 1)
        }
        .padding(.horizontal, Metrics.rowInset)
        .padding(.vertical, 5)
        .background(.bar)
    }

    private var nothingFound: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.secondary)
            Text(
                state.query.isEmpty
                    ? "Nothing needs a look."
                    : "No block contains “\(state.query)”."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(40)
    }

    // MARK: - Actions

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Button(model.preferences.mode.saveTitle) {
                model.save(model.preferences.mode)
            }
            .help("Save what you asked for before the run")

            Menu {
                Section("The three modes") {
                    ForEach(OutputMode.allCases) { mode in
                        Button(mode.displayName + "…") { model.save(mode) }
                    }
                }
                Section("Other arrangements") {
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
            } label: {
                Label("Other formats", systemImage: "square.and.arrow.down")
            }
            .help("Save this document some other way")

            Button("Translate another") { model.reset() }
        }
    }

    // MARK: - What is on screen

    private var translatableCount: Int {
        document.blocks.filter(\.source.kind.isTranslatable).count
    }

    private var summary: String {
        let engines = document.engines.readers.joined(separator: " + ")
        var said = "\(translatableCount) blocks, read by \(engines)."
        if document.needingAttention.isEmpty {
            said += " All passed every check."
        }
        if let translator = document.engines.translator {
            said += " Translated by \(translator)."
        }
        return said
    }

    private var visibleBlocks: [TranslatedBlock] {
        var blocks = state.onlyAttention
            ? document.needingAttention
            : document.blocks
        let query = state.query.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        if !query.isEmpty {
            blocks = blocks.filter { block in
                block.text.localizedCaseInsensitiveContains(query)
                    || block.source.text.localizedCaseInsensitiveContains(query)
            }
        }
        return blocks
    }

    private struct Page {
        let index: Int
        let blocks: [TranslatedBlock]
    }

    /// The visible blocks, back in page order.
    ///
    /// Filtering by attention re-sorts them worst-first, which is the right
    /// order for a list of problems and the wrong order for a document, so
    /// they are put back into reading order before being grouped.
    private var pages: [Page] {
        let grouped = Dictionary(
            grouping: visibleBlocks,
            by: { $0.source.pageIndex }
        )
        return grouped.keys.sorted().map { index in
            Page(
                index: index,
                blocks: (grouped[index] ?? []).sorted {
                    $0.source.order < $1.source.order
                }
            )
        }
    }

    private var target: TranslatedBlock.ID? {
        let flagged = document.needingAttention
        guard !flagged.isEmpty, state.cursor >= 0 else { return nil }
        return flagged[state.cursor % flagged.count].id
    }

    /// Wraps at both ends, so the arrows keep working at the last flagged
    /// block rather than going dead.
    private func step(_ delta: Int) {
        let count = document.needingAttention.count
        guard count > 0 else { return }
        if state.cursor < 0 {
            state.cursor = delta > 0 ? 0 : count - 1
        } else {
            state.cursor = ((state.cursor + delta) % count + count) % count
        }
    }
}
