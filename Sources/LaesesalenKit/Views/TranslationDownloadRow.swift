import Combine
import SwiftUI
import Translation

/// The one piece of setup the app can do for the reader.
///
/// macOS translates Simplified Chinese on the device, but the model is not on
/// the machine until someone asks for it, and only the system may ask —
/// which it does through this modifier, with its own confirmation. So the
/// button here does not download anything; it hands the request to macOS and
/// lets macOS ask.
///
/// Worth being plain about in the interface: this is a download *from Apple*,
/// of a model, once. The document is not involved and does not move.
struct TranslationDownloadRow: View {
    @ObservedObject var model: AppModel
    @StateObject private var state = DownloadState()

    final class DownloadState: ObservableObject {
        @Published var configuration: TranslationSession.Configuration?
        @Published var asked = false
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle")
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text("macOS has not downloaded Simplified Chinese yet")
                    .font(.callout)
                Text(
                    "A one-time download from Apple. Translating still "
                        + "happens on this Mac."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button(state.asked ? "Asking macOS…" : "Get it") {
                state.asked = true
                state.configuration = TranslationSession.Configuration(
                    source: Locale.Language(
                        identifier: model.languages.source.identifier
                    ),
                    target: Locale.Language(
                        identifier: model.languages.target.identifier
                    )
                )
            }
            .disabled(state.asked)
        }
        .padding(12)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .frame(maxWidth: 470)
        .translationTask(state.configuration) { session in
            // `prepareTranslation` is what raises the system's own download
            // prompt. It returns when the model is on the machine, or throws
            // if the reader declined.
            try? await session.prepareTranslation()
            await model.refreshEngines()
            state.asked = false
        }
    }
}
