import AppKit
import Combine
import DocCore
import DocIngest
import DocRender
import SwiftUI
import UniformTypeIdentifiers

/// The empty state, which is also the whole interface most of the time.
struct DropTargetView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var window: WindowState
    @StateObject private var drop = DropState()

    final class DropState: ObservableObject {
        @Published var isTargeted = false
    }

    var body: some View {
        VStack(spacing: 18) {
            Spacer()

            ZStack {
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(
                        style: StrokeStyle(lineWidth: 1.5, dash: [7, 6])
                    )
                    .foregroundStyle(
                        drop.isTargeted ? Color.accentColor : Color.secondary
                    )
                    .opacity(drop.isTargeted ? 1 : 0.4)

                VStack(spacing: 10) {
                    Image(systemName: "doc.text.viewfinder")
                        .font(.system(size: 40, weight: .light))
                        .foregroundStyle(.secondary)
                    Text("Drop a document here")
                        .font(.title3)
                    Text("PDF, PNG, or JPG — 简体中文 into English")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("Choose a file…") { choose() }
                        .padding(.top, 4)
                }
            }
            .frame(height: 230)
            .padding(.horizontal, 44)
            .onDrop(of: [.fileURL], isTargeted: $drop.isTargeted) { providers in
                model.open(fromProviders: providers)
            }

            OutputModePicker(model: model)

            if !model.brief.isEmpty {
                BriefSummary(model: model, window: window)
            }

            if model.translationNeedsDownload {
                TranslationDownloadRow(model: model)
            }

            if !model.canTranslate {
                Button {
                    window.showsEngines = true
                } label: {
                    Label(
                        "No translator is ready yet — see what is missing",
                        systemImage: "exclamationmark.triangle"
                    )
                }
                .buttonStyle(.link)
            }

            Text("Nothing you drop here is uploaded, indexed, or kept.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = DocumentLoader.readableTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.open(url)
    }
}

/// What the reader wants back, chosen before the work rather than after it.
///
/// The pipeline is the same for all three — the same readers, the same
/// disagreements settled, the same checks — so this is only ever about the
/// output. It is asked up front because it is the first thing anyone knows
/// about their own document and the last thing they want to be asked at the
/// end of a five-minute wait.
struct OutputModePicker: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 4) {
            Picker("", selection: $model.preferences.outputMode) {
                ForEach(OutputMode.allCases) { mode in
                    Text(mode.displayName).tag(mode.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 470)

            Text(model.preferences.mode.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
        }
    }
}

/// What the reader has already asked for, kept visible so an instruction
/// added last week is not silently applied to today's document.
struct BriefSummary: View {
    @ObservedObject var model: AppModel
    @ObservedObject var window: WindowState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(model.brief.guidanceLines.prefix(3)), id: \.self) {
                line in
                Label(line, systemImage: "text.quote")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Button("Edit the brief") { window.showsBrief = true }
                .buttonStyle(.link)
                .font(.footnote)
        }
        .frame(maxWidth: 470, alignment: .leading)
    }
}
