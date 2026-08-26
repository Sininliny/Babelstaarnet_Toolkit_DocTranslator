import DocCore
import SwiftUI

/// The furniture every screen is built from.
///
/// This file exists because the same eight lines were written eight times.
/// A badge, a caption in orange with a triangle beside it, a section title
/// with an explanation under it — each of those was a small pile of
/// modifiers repeated in `EngineListView`, `ModelManagerView`, `BlockRow`
/// and `DocumentView`, and each copy had drifted: three different corner
/// radii, two different oranges, captions that were `.caption` in one place
/// and `.system(size: 12)` in another.
///
/// Naming them once is not tidiness. A reader learns an interface by
/// noticing that two things that look the same behave the same, and that
/// only works if the app is disciplined about when things look the same.
enum Metrics {
    /// The margin every panel and every sheet uses.
    static let gutter: CGFloat = 18
    /// The margin inside a row of a list.
    static let rowInset: CGFloat = 14
    static let cardRadius: CGFloat = 10
    /// The stripe down the side of a block that needs a look.
    static let edge: CGFloat = 3
    /// Below this, the Chinese and the English stop sitting side by side and
    /// stack instead. Two columns of text in less than this is two columns
    /// of hyphenation.
    static let stackBelow: CGFloat = 720
    static let minWindowWidth: CGFloat = 820
    static let minWindowHeight: CGFloat = 620
}

// MARK: - Confidence, said in more than one way

extension Confidence.Band {
    /// A shape as well as a colour.
    ///
    /// The old interface drew confidence as a three-point coloured stripe and
    /// nothing else, which meant the single most important thing this app has
    /// to say about a block — whether to trust it — was carried entirely by
    /// the difference between red and orange. That is invisible to a reader
    /// with deuteranopia and invisible to anyone printing the window. So the
    /// band now says itself three ways: a symbol, a word, and a colour.
    var symbol: String {
        switch self {
        case .high: return "checkmark.circle.fill"
        case .check: return "eye.trianglebadge.exclamationmark.fill"
        case .low: return "exclamationmark.triangle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .high: return .green
        case .check: return .orange
        case .low: return .red
        }
    }

    /// What the stripe down the left of a block row is painted with. Nothing,
    /// for a block that passed: a document where every row is striped has
    /// told the reader nothing about which row to look at.
    var edgeTint: Color {
        self == .high ? .clear : tint
    }
}

/// The band, as a thing you can read rather than a colour you have to know.
struct ConfidenceChip: View {
    let band: Confidence.Band
    var compact = false

    var body: some View {
        Label {
            if !compact { Text(band.label) }
        } icon: {
            Image(systemName: band.symbol)
        }
        .labelStyle(.titleAndIcon)
        .font(.caption.weight(.medium))
        .foregroundStyle(band.tint)
        .padding(.horizontal, compact ? 0 : 7)
        .padding(.vertical, compact ? 0 : 2)
        .background(
            compact
                ? nil
                : Capsule().fill(band.tint.opacity(0.12))
        )
        .accessibilityLabel(band.label)
    }
}

// MARK: - Small pieces of type

/// A neutral label: "built in", "on this Mac", "suits this Mac".
struct Badge: View {
    let text: String
    var tint: Color = .secondary

    init(_ text: String, tint: Color = .secondary) {
        self.text = text
        self.tint = tint
    }

    var body: some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.14)))
    }
}

/// Something the reader should know about, in the one shape the whole app
/// uses for it.
struct NoteLabel: View {
    enum Tone {
        case quiet
        case caution
        case problem
        case action

        var symbol: String {
            switch self {
            case .quiet: return "info.circle"
            case .caution: return "exclamationmark.triangle"
            case .problem: return "exclamationmark.octagon"
            case .action: return "arrow.right.circle"
            }
        }

        var tint: Color {
            switch self {
            case .quiet: return .secondary
            case .caution: return .orange
            case .problem: return .red
            case .action: return .accentColor
            }
        }
    }

    let text: String
    var tone: Tone = .quiet
    var symbol: String?

    init(_ text: String, tone: Tone = .quiet, symbol: String? = nil) {
        self.text = text
        self.tone = tone
        self.symbol = symbol
    }

    var body: some View {
        Label(text, systemImage: symbol ?? tone.symbol)
            .font(.caption)
            .foregroundStyle(tone.tint)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A title with the sentence that says what the section is for. Every panel
/// in the app has these; they were four different sizes.
struct SectionHeader: View {
    let title: String
    var explanation: String?

    init(_ title: String, _ explanation: String? = nil) {
        self.title = title
        self.explanation = explanation
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            if let explanation {
                Text(explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The head of a sheet or a settings tab: a title, a sentence, a rule.
struct PanelHeader: View {
    let title: String
    var explanation: String?

    init(_ title: String, _ explanation: String? = nil) {
        self.title = title
        self.explanation = explanation
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.headline)
            if let explanation {
                Text(explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Metrics.gutter)
    }
}

/// The row of buttons along the bottom of a sheet.
struct PanelFooter<Leading: View>: View {
    let note: String?
    @ViewBuilder var leading: Leading
    let done: () -> Void

    init(
        note: String? = nil,
        @ViewBuilder leading: () -> Leading = { EmptyView() },
        done: @escaping () -> Void
    ) {
        self.note = note
        self.leading = leading()
        self.done = done
    }

    var body: some View {
        HStack(spacing: 10) {
            leading
            if let note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button("Done", action: done)
                .keyboardShortcut(.defaultAction)
        }
        .padding(Metrics.rowInset)
    }
}

// MARK: - Surfaces

extension View {
    /// A panel that reads as one thing rather than as loose rows.
    func card(
        padding: CGFloat = 14,
        tint: Color? = nil
    ) -> some View {
        self
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: Metrics.cardRadius)
                    .fill(tint?.opacity(0.09) ?? Color.secondary.opacity(0.07))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.cardRadius)
                    .strokeBorder(
                        (tint ?? .primary).opacity(tint == nil ? 0.08 : 0.25)
                    )
            )
    }
}

/// A word or two on a tinted ground, for the things that arrive in a row and
/// have to wrap: what each reader reported, how long it took.
struct Chip: View {
    let text: String
    var symbol: String?

    init(_ text: String, symbol: String? = nil) {
        self.text = text
        self.symbol = symbol
    }

    var body: some View {
        Label {
            Text(text)
        } icon: {
            if let symbol { Image(systemName: symbol) }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.secondary.opacity(0.1)))
    }
}

/// Chips that run out of room and wrap, rather than clipping.
///
/// A row of `Label`s in an `HStack` is what the working screen used to show
/// while three readers reported in, and the third one fell off the end of the
/// window. This is the one layout in the app that has to reflow.
struct WrappingRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = arrange(subviews, in: width)
        let height = rows.reduce(0) { $0 + $1.height + spacing }
        return CGSize(
            width: proposal.width ?? rows.map(\.width).max() ?? 0,
            height: max(0, height - spacing)
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var y = bounds.minY
        for row in arrange(subviews, in: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, in width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = row.indices.isEmpty
                ? size.width
                : row.width + spacing + size.width
            if needed > width, !row.indices.isEmpty {
                rows.append(row)
                row = Row()
            }
            row.width = row.indices.isEmpty
                ? size.width
                : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}

// MARK: - How wide the window is

/// What the list is being drawn into.
///
/// Two columns of text is the right way to show a translation beside its
/// source and the wrong way to show it in four hundred points: the Chinese
/// and the English both end up a couple of words wide. The rows need to know,
/// and a row cannot measure the window it is in without every row measuring
/// it separately, so the container measures once and the rows are told.
final class LayoutState: ObservableObject {
    @Published var width: CGFloat = 1_000

    var isNarrow: Bool { width < Metrics.stackBelow }
}

extension View {
    /// Report this view's width into a `LayoutState`.
    func measuringWidth(into layout: LayoutState) -> some View {
        onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            if abs(layout.width - width) > 1 { layout.width = width }
        }
    }
}
