import AppKit
import Combine
import DocCore
import DocIngest
import DocRender
import SwiftUI
import UniformTypeIdentifiers

/// The empty state, which is also the whole interface most of the time.
///
/// It used to be a single column of unrelated things — a dashed box, a
/// segmented picker, a summary of the brief, a download offer, a warning, a
/// footnote — each centred, each the same weight, stacked between two
/// `Spacer`s with no scroll view behind them. With every optional row present
/// at the minimum window height the bottom of it was simply cut off.
///
/// There are three jobs on this screen and they are now three groups. What
/// you do (drop something). What you get (the mode). What is not ready yet.
/// The last of those is missing on a Mac where everything works, which is the
/// point: a first-run warning and a permanent fixture should not look alike.
struct DropTargetView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var window: WindowState
    @StateObject private var drop = DropState()
    @Environment(\.openSettings) private var openSettings

    final class DropState: ObservableObject {
        @Published var isTargeted = false
        /// Said out loud rather than failing quietly: ⌘V with a screenshot on
        /// the clipboard is the commonest way a single page arrives, and ⌘V
        /// with nothing on it must not look like a broken app.
        @Published var pasteProblem: String?
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                well
                modes
                if hasSomethingToSay { setup }
                footnote
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The whole screen takes a drop, not just the dashed rectangle. The
        // rectangle is where the eye goes; the window is where the file lands.
        .onDrop(of: [.fileURL], isTargeted: $drop.isTargeted) { providers in
            model.open(fromProviders: providers)
        }
    }

    // MARK: - Where the document goes

    private var well: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18)
                .fill(
                    drop.isTargeted
                        ? Color.accentColor.opacity(0.08)
                        : Color.secondary.opacity(0.04)
                )
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(
                    style: StrokeStyle(
                        lineWidth: drop.isTargeted ? 2 : 1.5,
                        dash: [7, 6]
                    )
                )
                .foregroundStyle(
                    drop.isTargeted ? Color.accentColor : Color.secondary
                )
                .opacity(drop.isTargeted ? 1 : 0.35)

            VStack(spacing: 10) {
                Image(
                    systemName: drop.isTargeted
                        ? "arrow.down.doc"
                        : "doc.text.viewfinder"
                )
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(
                    drop.isTargeted ? Color.accentColor : .secondary
                )
                .contentTransition(.symbolEffect(.replace))

                Text(
                    drop.isTargeted
                        ? "Drop it here"
                        : "Drop a document here"
                )
                .font(.title3.weight(.medium))

                Text("PDF, PNG, or JPG — 简体中文 into English")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    Button("Choose a file…") { model.openWithPanel() }
                    Button("Paste a page") { paste() }
                }
                .padding(.top, 4)

                if let problem = drop.pasteProblem {
                    NoteLabel(problem, tone: .caution)
                }
            }
            .padding(20)
        }
        .frame(minHeight: 190, maxHeight: 230)
        .animation(.smooth(duration: 0.18), value: drop.isTargeted)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Drop a document to translate")
    }

    // MARK: - What comes back

    /// Chosen before the work rather than after it.
    ///
    /// The pipeline is the same for all three — the same readers, the same
    /// disagreements settled, the same checks — so this is only ever about
    /// the output. It is asked up front because it is the first thing anyone
    /// knows about their own document and the last thing they want to be
    /// asked at the end of a five-minute wait.
    ///
    /// It was a segmented control whose three segments are sentences —
    /// "The same document, in English" inside a 470-point picker — and every
    /// one of them was truncated to about a word. Three cards fit what a
    /// segment could not: the name, the picture, and the sentence saying what
    /// the file will be.
    private var modes: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader("What you get back")
            HStack(alignment: .top, spacing: 10) {
                ForEach(OutputMode.allCases) { mode in
                    ModeCard(
                        mode: mode,
                        isChosen: model.preferences.mode == mode
                    ) {
                        model.preferences.outputMode = mode.rawValue
                    }
                }
            }
        }
    }

    // MARK: - What is not ready

    private var hasSomethingToSay: Bool {
        !model.canTranslate
            || model.translationNeedsDownload
            || !model.brief.isEmpty
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !model.canTranslate {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("No translator is ready yet")
                            .font(.callout.weight(.medium))
                        Text(
                            "A document dropped now would not get far. Each "
                                + "missing engine says what would fix it."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Button("See what is missing") {
                        window.settingsTab = .engines
                        openSettings()
                    }
                }
            }

            if model.translationNeedsDownload {
                if !model.canTranslate { Divider() }
                TranslationDownloadRow(model: model)
            }

            if !model.brief.isEmpty {
                if !model.canTranslate || model.translationNeedsDownload {
                    Divider()
                }
                BriefSummary(model: model, window: window)
            }
        }
        .card()
    }

    private var footnote: some View {
        Label(
            "Nothing you drop here is uploaded, indexed, or kept.",
            systemImage: "lock"
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
    }

    // MARK: - Getting a document in

    private func paste() {
        drop.pasteProblem = model.openFromPasteboard()
            ? nil
            : "There is no page on the clipboard — copy a PDF, an image, or "
                + "a file first."
    }
}

// MARK: - One of the three

struct ModeCard: View {
    let mode: OutputMode
    let isChosen: Bool
    let choose: () -> Void

    @StateObject private var hover = HoverState()

    final class HoverState: ObservableObject {
        @Published var inside = false
    }

    var body: some View {
        Button(action: choose) {
            face
        }
        .buttonStyle(.plain)
        .onHover { hover.inside = $0 }
        .help(mode.explanation)
        .accessibilityLabel(mode.displayName)
        .accessibilityValue(isChosen ? "chosen" : "")
        .accessibilityAddTraits(isChosen ? [.isSelected] : [])
    }

    private var face: some View {
        VStack(alignment: .leading, spacing: 6) {
            top
            Text(mode.shortName)
                .font(.callout.weight(.medium))
                .foregroundStyle(.primary)
            Text(mode.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(ground)
        .overlay(border)
        .contentShape(Rectangle())
    }

    private var top: some View {
        HStack {
            Image(systemName: mode.symbol)
                .font(.system(size: 17))
                .foregroundStyle(isChosen ? Color.accentColor : Color.secondary)
            Spacer()
            Image(systemName: isChosen ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(
                    isChosen ? Color.accentColor : Color.secondary.opacity(0.5)
                )
        }
    }

    private var ground: some View {
        let fill: Color = isChosen
            ? Color.accentColor.opacity(0.1)
            : Color.secondary.opacity(hover.inside ? 0.1 : 0.05)
        return RoundedRectangle(cornerRadius: Metrics.cardRadius).fill(fill)
    }

    private var border: some View {
        let stroke: Color = isChosen
            ? Color.accentColor.opacity(0.6)
            : Color.primary.opacity(0.08)
        return RoundedRectangle(cornerRadius: Metrics.cardRadius)
            .strokeBorder(stroke, lineWidth: isChosen ? 1.5 : 1)
    }
}

// MARK: - The brief, in passing

/// What the reader has already asked for, kept visible so an instruction
/// added last week is not silently applied to today's document.
struct BriefSummary: View {
    @ObservedObject var model: AppModel
    @ObservedObject var window: WindowState

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "text.quote")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(
                    "\(model.brief.guidanceLines.count) "
                        + (model.brief.guidanceLines.count == 1
                            ? "instruction" : "instructions")
                        + " will be applied"
                )
                .font(.callout.weight(.medium))
                ForEach(
                    Array(model.brief.guidanceLines.prefix(3)),
                    id: \.self
                ) { line in
                    Text(line)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if model.brief.guidanceLines.count > 3 {
                    Text("and \(model.brief.guidanceLines.count - 3) more")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 8)
            Button("Edit the brief") { window.showsBrief = true }
        }
    }
}
