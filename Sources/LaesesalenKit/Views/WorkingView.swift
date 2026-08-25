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
struct WorkingView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(model.progress.activity)
                        .font(.callout)
                    Spacer()
                    if model.progress.pageCount > 1 {
                        Text(
                            "Page \(model.progress.currentPage + 1) of "
                                + "\(model.progress.pageCount)"
                        )
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    }
                }
                ProgressView(value: model.progress.fraction)
                if !model.progress.readerNotes.isEmpty {
                    HStack(spacing: 14) {
                        ForEach(model.progress.readerNotes, id: \.self) {
                            note in
                            Label(note, systemImage: "eye")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
            }
            .padding(14)

            Divider()

            if model.translated.isEmpty {
                Spacer()
                Text("Reading the page…")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.translated) { block in
                            BlockRow(block: block)
                            Divider()
                        }
                    }
                }
            }
        }
    }
}
