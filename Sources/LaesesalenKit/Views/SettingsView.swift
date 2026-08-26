import Combine
import DocAgents
import DocCore
import DocRender
import SwiftUI

/// The settings window.
///
/// Two of these tabs used to be sheets, and one of them opened the other as a
/// second sheet on top of itself. A sheet is a question the app is asking and
/// has to have answered before anything else can happen; neither "which
/// engines exist on this Mac" nor "what has been downloaded" is a question of
/// that kind. Both are reference, both are consulted *while* looking at
/// something else, and a modal is precisely the wrong container for anything
/// you want to read beside your document.
///
/// So they are a settings window, at command-comma, where a Mac user already
/// looks. The document window stays live behind it.
public struct SettingsView: View {
    @ObservedObject private var model: AppModel
    @ObservedObject private var window: WindowState

    public init(model: AppModel, window: WindowState) {
        self.model = model
        self.window = window
    }

    public var body: some View {
        TabView(selection: $window.settingsTab) {
            EngineSettings(model: model)
                .tabItem {
                    Label(
                        SettingsTab.engines.title,
                        systemImage: SettingsTab.engines.symbol
                    )
                }
                .tag(SettingsTab.engines)

            ModelSettings(model: model)
                .tabItem {
                    Label(
                        SettingsTab.models.title,
                        systemImage: SettingsTab.models.symbol
                    )
                }
                .tag(SettingsTab.models)

            DefaultsSettings(model: model)
                .tabItem {
                    Label(
                        SettingsTab.defaults.title,
                        systemImage: SettingsTab.defaults.symbol
                    )
                }
                .tag(SettingsTab.defaults)
        }
        .frame(width: 640, height: 560)
        .task { await model.refreshEngines() }
    }
}

/// What every document starts with.
///
/// The split this tab exists to make is between an instruction for *this*
/// document and an instruction for *every* document. The brief sheet used to
/// hold both, with a link at the bottom reading "Use these for every document
/// from now on" — which meant a standing instruction could only be created by
/// first writing a one-off and then promoting it, and once promoted there was
/// nowhere at all to see or remove it. A house style you cannot find is a
/// house style silently applied to a document it is wrong for.
struct DefaultsSettings: View {
    @ObservedObject var model: AppModel
    @StateObject private var draft = Draft()

    final class Draft: ObservableObject {
        @Published var instruction = ""
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                standing
                Divider()
                asking
                Divider()
                startingMode
                Divider()
                translator
            }
            .padding(Metrics.gutter)
        }
    }

    // MARK: - Standing instructions

    private var standing: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(
                "Standing instructions",
                "Applied to every document, until removed. House style, a "
                    + "name that always stays in Chinese, a field's "
                    + "vocabulary."
            )

            if model.preferences.standingInstructions.isEmpty {
                Text("None. Every document starts with an empty brief.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(
                Array(model.preferences.standingInstructions.enumerated()),
                id: \.offset
            ) { index, instruction in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "text.quote")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(instruction)
                        .font(.callout)
                    Spacer(minLength: 8)
                    Button {
                        model.preferences.standingInstructions.remove(
                            at: index
                        )
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Stop applying this to every document")
                    .accessibilityLabel("Remove standing instruction")
                }
            }

            HStack {
                TextField("Add a standing instruction", text: $draft.instruction)
                    .onSubmit(add)
                Button("Add", action: add).disabled(!canAdd)
            }

            NoteLabel(
                "A standing instruction is added to the brief of every new "
                    + "document. Removing it here does not change a document "
                    + "already open.",
                tone: .quiet
            )
        }
    }

    // MARK: - Questions

    private var asking: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(
                "Questions before translating",
                "Where a document has two defensible readings, the app can "
                    + "ask you once — at most three questions — before it "
                    + "starts."
            )
            Toggle(
                "Ask me about the document before translating",
                isOn: $model.preferences.askClarifyingQuestions
            )
        }
    }

    // MARK: - The mode a document starts in

    private var startingMode: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(
                "What a document starts as",
                "The mode a new document is set to. It can still be changed "
                    + "on the drop screen before you translate."
            )
            Picker("", selection: $model.preferences.outputMode) {
                ForEach(OutputMode.allCases) { mode in
                    Text(mode.shortName).tag(mode.rawValue)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(maxWidth: 380)
            Text(model.preferences.mode.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Which translator leads

    /// A real choice that had no control anywhere in the app.
    ///
    /// It was stored, decoded, defaulted and handed to the pipeline, and the
    /// only way to change it was to edit the preferences file. The difference
    /// it makes is the difference between a translation that obeys the brief
    /// and one that cannot read it, which is not a detail.
    private var translator: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(
                "Which translator leads",
                "Both are on this Mac. They fail differently."
            )
            Picker("", selection: $model.preferences.translatorPreference) {
                Text("The one that follows instructions")
                    .tag(Engines.TranslatorPreference.followsInstructions
                        .rawValue)
                Text("The fastest one")
                    .tag(Engines.TranslatorPreference.fastest.rawValue)
            }
            .labelsHidden()
            .pickerStyle(.radioGroup)

            Text(
                model.preferences.preference == .followsInstructions
                    ? "A language model translates. It is the only translator "
                        + "that can read the brief, keep a term consistent "
                        + "across pages, or be told the register — and it is "
                        + "slower."
                    : "Apple's translation model translates. Faster and "
                        + "steadier, and deaf to the brief: pinned words and "
                        + "instructions are still checked afterwards, but "
                        + "nothing acts on them while translating."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            if model.preferences.preference == .fastest,
               !model.brief.isEmpty {
                NoteLabel(
                    "This document's brief has "
                        + "\(model.brief.guidanceLines.count) instructions "
                        + "the fastest translator cannot read.",
                    tone: .caution
                )
            }
        }
    }

    private var canAdd: Bool {
        !draft.instruction
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
    }

    private func add() {
        let trimmed = draft.instruction
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        model.preferences.standingInstructions.append(trimmed)
        draft.instruction = ""
    }
}
