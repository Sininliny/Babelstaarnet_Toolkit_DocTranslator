import Combine
import DocCore
import SwiftUI

/// What the app shows while it works.
///
/// The blocks appear as they are finished rather than at the end. A page can
/// take a minute, and a reader watching a bar creep along has no way to tell
/// a slow document from a stuck one — but a reader watching English arrive
/// paragraph by paragraph can see exactly which paragraph it is on, and can
/// start reading before it is done.
///
/// Three things were missing from that. How long it has been going, which is
/// the actual question behind "is this stuck" and which a fraction cannot
/// answer. A way to stop without going to the toolbar. And a layout for the
/// readers' reports that does not fall off the end of the window when a third
/// reader files one — they were a plain `HStack`, and the third one was
/// simply not visible.
struct WorkingView: View {
    @ObservedObject var model: AppModel
    @StateObject private var layout = LayoutState()

    var body: some View {
        VStack(spacing: 0) {
            status
            Divider()
            stream
        }
    }

    // MARK: - What is happening

    private var status: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text(model.progress.activity)
                    .font(.callout.weight(.medium))
                Spacer(minLength: 8)
                if model.progress.pageCount > 1 {
                    Text(
                        "Page \(model.progress.currentPage + 1) of "
                            + "\(model.progress.pageCount)"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                }
                elapsed
                Button("Stop") { model.cancel() }
                    .controlSize(.small)
                    .help("Stop translating (⌘.)")
            }

            ProgressView(value: model.progress.fraction)
                .accessibilityLabel("Translation progress")
                .accessibilityValue(
                    "\(Int(model.progress.fraction * 100)) percent"
                )

            if !model.profile.isEmpty { profileNote }

            if !model.progress.readerNotes.isEmpty {
                WrappingRow(spacing: 6) {
                    ForEach(model.progress.readerNotes, id: \.self) { note in
                        Chip(note, symbol: "eye")
                    }
                }
            }
        }
        .padding(Metrics.rowInset)
    }

    /// How long it has been going.
    ///
    /// A `TimelineView` rather than a timer the model owns: the elapsed
    /// figure is a fact about the clock, not a fact about the job, and
    /// republishing the whole model once a second to redraw one label would
    /// redraw every block already on screen with it.
    private var elapsed: some View {
        Group {
            if let startedAt = model.startedAt {
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    Text(
                        Self.duration.string(
                            from: context.date.timeIntervalSince(startedAt)
                        ) ?? ""
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                }
            }
        }
    }

    private static let duration: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.minute, .second]
        formatter.zeroFormattingBehavior = .pad
        formatter.unitsStyle = .positional
        return formatter
    }()

    /// Shown while the work is happening, not afterwards: a wrong reading of
    /// what the document is will be applied to every sentence, and the reader
    /// is the only one who can see that it is wrong.
    private var profileNote: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "text.book.closed")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("Reading it as")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(model.profile.summary)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                // What the app looked up, shown as it looked it up. A name
                // is the one decision here that a reader can check without
                // reading a word of the source — they know what they are
                // taking — and it is also the one that does the most damage
                // when it is wrong.
                if !model.profile.names.isEmpty {
                    Text(lookedUp)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .card(padding: 10)
    }

    /// The names the document settled, and how many more there were. Three,
    /// because this sits above a running translation and is not the place to
    /// list twenty — the whole list goes into the export, where there is room
    /// for it and where someone reading the English months later can still
    /// find it.
    private var lookedUp: String {
        let names = model.profile.nameSummary
        let shown = names.prefix(3).joined(separator: ", ")
        guard names.count > 3 else { return "Looked up: " + shown }
        return "Looked up: \(shown), and \(names.count - 3) more"
    }

    // MARK: - The English as it arrives

    private var stream: some View {
        Group {
            if model.translated.isEmpty {
                waiting
            } else {
                ScrollViewReader { scroller in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(model.translated) { block in
                                BlockRow(
                                    block: block,
                                    mode: model.preferences.mode,
                                    isNarrow: layout.isNarrow
                                )
                                .id(block.id)
                                Divider()
                            }
                            // Something to scroll to that is not a block, so
                            // the last block is not left half under the edge.
                            Color.clear.frame(height: 1).id(Self.foot)
                        }
                    }
                    .measuringWidth(into: layout)
                    .onChange(of: model.translated.count) {
                        withAnimation(.smooth(duration: 0.25)) {
                            scroller.scrollTo(Self.foot, anchor: .bottom)
                        }
                    }
                }
            }
        }
    }

    private static let foot = "foot"

    private var waiting: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.large)
            Text("Reading the page…")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(
                "Both readers look at the whole page before the first "
                    + "sentence is translated."
            )
            .font(.caption)
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 340)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
