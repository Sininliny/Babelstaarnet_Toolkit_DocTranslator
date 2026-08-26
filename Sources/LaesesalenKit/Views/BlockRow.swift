import AppKit
import Combine
import DocCore
import DocRender
import SwiftUI

/// One block: the Chinese, the English, and what the app thinks of its own
/// answer.
///
/// The confidence is a colour on the left edge and a sentence underneath, and
/// never a number. "0.62" is not something a reader can act on; "the readers
/// disagreed — "未" against "末" — and Vision OCR was chosen" is.
///
/// Four things changed here, and three of them are about a row saying what it
/// knows rather than implying it.
///
/// The band was a three-point coloured stripe and nothing else — the single
/// most important judgement in the app carried entirely by the difference
/// between red and orange, which is no difference at all to a reader who
/// cannot separate them or to a printed window. It now says itself in a
/// symbol and a word as well.
///
/// The findings carry `evidence` — "the exact text that triggered it, so the
/// interface can point at it rather than describe it", as the type's own
/// comment puts it — and no interface ever pointed at it. It is shown now.
///
/// So is the context the block was translated with, which the side-by-side
/// export has always shown and the window never did.
///
/// And the row no longer sets two columns of text regardless of how much room
/// it has, or shows the Chinese to a reader who asked for just the text.
struct BlockRow: View {
    let block: TranslatedBlock
    var mode: OutputMode = .sideBySide
    var isNarrow = false
    @StateObject private var state = RowState()

    final class RowState: ObservableObject {
        @Published var showsWorking = false
        @Published var hovering = false
        @Published var copied = false
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Rectangle()
                .fill(block.confidence.band.edgeTint)
                .frame(width: Metrics.edge)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 8) {
                if showsHeading { heading }
                text
                notes
                if block.source.wasContested || block.wasRevised {
                    working
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal, Metrics.rowInset)
        }
        .background(
            block.confidence.band == .high
                ? Color.clear
                : block.confidence.band.tint.opacity(0.04)
        )
        .overlay(alignment: .topTrailing) { copyButton }
        .onHover { state.hovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(spoken)
    }

    // MARK: - The line above the text

    /// Only drawn when it has something to say. A badge on every row is a
    /// badge nobody reads.
    private var heading: some View {
        HStack(spacing: 6) {
            if block.source.kind != .paragraph {
                Badge(kindName)
            }
            if block.confidence.band != .high {
                ConfidenceChip(band: block.confidence.band)
            }
            Spacer(minLength: 0)
        }
    }

    /// Floated over the row rather than placed in it: as a row in the stack
    /// it appeared on hover and pushed every line below it down, so passing
    /// the pointer over a document made the document move.
    private var copyButton: some View {
        Button(action: copy) {
            Image(systemName: state.copied ? "checkmark" : "doc.on.doc")
                .font(.caption)
                .padding(5)
                .background(
                    Circle().fill(Color.primary.opacity(0.06))
                )
        }
        .buttonStyle(.plain)
        .foregroundStyle(state.copied ? Color.green : .secondary)
        .padding(.top, 6)
        .padding(.trailing, 6)
        .opacity(state.hovering ? 1 : 0)
        .help("Copy the English of this block")
        .accessibilityLabel("Copy this block")
    }

    private var showsHeading: Bool {
        block.source.kind != .paragraph
            || block.confidence.band != .high
    }

    private var kindName: String {
        switch block.source.kind {
        case .heading: return "heading"
        case .paragraph: return "paragraph"
        case .listItem: return "list item"
        case .tableRow: return "table row"
        case .caption: return "caption"
        case .pageFurniture: return "page furniture"
        }
    }

    // MARK: - The text itself

    /// One column or two, depending on the room and on what the reader asked
    /// for. Someone who chose "just the text" is not checking a translation
    /// against its source and does not need half the window given to a
    /// language they said they could not read.
    private var text: some View {
        Group {
            if mode == .plainText {
                english
            } else if isNarrow {
                VStack(alignment: .leading, spacing: 6) {
                    source
                    english
                }
            } else {
                HStack(alignment: .top, spacing: 18) {
                    source
                    english
                }
            }
        }
    }

    private var source: some View {
        Text(block.source.text)
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var english: some View {
        Text(block.text)
            .font(englishFont)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - What the app is unsure about

    private var notes: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(plainReasons, id: \.self) { reason in
                NoteLabel(
                    reason,
                    tone: block.confidence.band == .low ? .problem : .caution,
                    symbol: "exclamationmark.circle"
                )
            }
            ForEach(block.findings) { finding in
                FindingNote(finding: finding)
            }
            if block.context.wasWidened || block.context.retriedAlone {
                NoteLabel(
                    "Translated with " + block.context.reasons.joined(
                        separator: ", "
                    ),
                    tone: .quiet,
                    symbol: "text.append"
                )
            }
        }
    }

    /// The reasons that are not a finding's message.
    ///
    /// Every finding's message is copied into the confidence reasons by
    /// `ConfidenceScoring`, so showing both lists whole would print each of
    /// them twice — once without its evidence and once with.
    private var plainReasons: [String] {
        let fromFindings = Set(block.findings.map(\.message))
        return block.confidence.reasons.filter { !fromFindings.contains($0) }
    }

    // MARK: - How it was read

    private var working: some View {
        DisclosureGroup(isExpanded: $state.showsWorking) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(
                    block.source.candidates.sorted(by: {
                        $0.key.rawValue < $1.key.rawValue
                    }),
                    id: \.key
                ) { reader, text in
                    workingRow(reader.displayName, text)
                }
                workingRow("Settled", block.source.settlement.summary)
                if block.wasRevised {
                    workingRow("First draft", block.firstDraft)
                }
            }
            .font(.caption)
            .padding(.top, 4)
        } label: {
            Text("How this block was read")
                .font(.caption)
        }
        .font(.caption)
    }

    private func workingRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(label + ":")
                .foregroundStyle(.secondary)
                .frame(width: 118, alignment: .trailing)
            Text(value).textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Furniture

    private var englishFont: Font {
        block.source.kind == .heading
            ? .system(size: 15, weight: .semibold)
            : .system(size: 14)
    }

    /// What a screen reader gets, which is otherwise a stripe and two
    /// unlabelled runs of text in two languages.
    private var spoken: String {
        var said = "\(kindName). \(block.text)."
        if block.confidence.band != .high {
            said += " \(block.confidence.band.label)."
            said += " " + block.confidence.reasons.joined(separator: ". ")
        }
        return said
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(block.text, forType: .string)
        state.copied = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            state.copied = false
        }
    }
}

/// A finding, pointing at the text that caused it.
struct FindingNote: View {
    let finding: IntegrityFinding

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            NoteLabel(
                finding.message,
                tone: tone,
                symbol: "exclamationmark.circle"
            )
            if let evidence = finding.evidence, !evidence.isEmpty {
                Text(evidence)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.leading, 8)
                    .padding(.vertical, 1)
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(tone.tint.opacity(0.5))
                            .frame(width: 2)
                    }
                    .padding(.leading, 18)
            }
        }
    }

    private var tone: NoteLabel.Tone {
        switch finding.severity {
        case .blocking: return .problem
        case .caution: return .caution
        case .note: return .quiet
        }
    }
}
