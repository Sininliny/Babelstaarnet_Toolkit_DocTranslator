import Combine
import DocCore
import SwiftUI

/// One block: the Chinese, the English, and what the app thinks of its own
/// answer.
///
/// The confidence is a colour on the left edge and a sentence underneath, and
/// never a number. "0.62" is not something a reader can act on; "the readers
/// disagreed — “未” against “末” — and Vision OCR was chosen" is.
struct BlockRow: View {
    let block: TranslatedBlock
    @StateObject private var state = RowState()

    final class RowState: ObservableObject {
        @Published var showsWorking = false
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Rectangle()
                .fill(edgeColor)
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 18) {
                    Text(block.source.text)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Text(block.text)
                        .font(englishFont)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if block.confidence.band != .high {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(block.confidence.reasons, id: \.self) {
                            reason in
                            Label(reason, systemImage: "exclamationmark.circle")
                                .font(.caption)
                                .foregroundStyle(noteColor)
                        }
                    }
                }

                if block.source.wasContested || block.wasRevised {
                    DisclosureGroup(
                        isExpanded: $state.showsWorking
                    ) {
                        working
                    } label: {
                        Text("How this block was read")
                            .font(.caption)
                    }
                    .font(.caption)
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 14)
        }
    }

    private var working: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(
                block.source.candidates.sorted(by: {
                    $0.key.rawValue < $1.key.rawValue
                }),
                id: \.key
            ) { reader, text in
                HStack(alignment: .top, spacing: 6) {
                    Text(reader.displayName + ":")
                        .foregroundStyle(.secondary)
                        .frame(width: 118, alignment: .trailing)
                    Text(text).textSelection(.enabled)
                }
            }
            HStack(alignment: .top, spacing: 6) {
                Text("Settled:")
                    .foregroundStyle(.secondary)
                    .frame(width: 118, alignment: .trailing)
                Text(block.source.settlement.summary)
            }
            if block.wasRevised {
                HStack(alignment: .top, spacing: 6) {
                    Text("First draft:")
                        .foregroundStyle(.secondary)
                        .frame(width: 118, alignment: .trailing)
                    Text(block.firstDraft).textSelection(.enabled)
                }
            }
        }
        .font(.caption)
        .padding(.top, 4)
    }

    private var englishFont: Font {
        block.source.kind == .heading
            ? .system(size: 15, weight: .semibold)
            : .system(size: 14)
    }

    private var edgeColor: Color {
        switch block.confidence.band {
        case .high: return .clear
        case .check: return .orange
        case .low: return .red
        }
    }

    private var noteColor: Color {
        block.confidence.band == .low ? .red : .orange
    }
}
