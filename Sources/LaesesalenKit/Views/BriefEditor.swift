import Combine
import DocCore
import SwiftUI

/// What the reader wants from this translation, in their own words.
///
/// The two halves do different jobs. An instruction is prose handed to the
/// translating model and to the reviewer — it can say anything, and nothing
/// mechanical checks it. A glossary term is a promise the app can *keep*:
/// where the source contains the term, the English must contain what the
/// reader asked for, and `TextIntegrity` marks the block if it does not. So
/// "keep names in Chinese" belongs in the instructions, and "keep 王小明 in
/// Chinese" belongs in the glossary, where it is enforced rather than
/// requested.
///
/// That distinction is the whole point of the sheet and it was nowhere on it:
/// the two sections sat under headings reading "Instructions" and "Particular
/// words", each with an explanation that described what to type rather than
/// what the app would do about it. They are now labelled by the difference
/// that matters — one is asked for, the other is checked.
struct BriefEditor: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var draft = Draft()

    final class Draft: ObservableObject {
        @Published var instruction = ""
        @Published var term = ""
        @Published var rendering = ""
        @Published var keepAsWritten = true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelHeader(
                "Translation brief",
                "Anything you would tell a human translator, for this "
                    + "document. It is applied to every block and shown to "
                    + "the reviewer."
            )

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    instructions
                    Divider()
                    glossary
                    if !model.brief.settledQuestions.isEmpty {
                        Divider()
                        questions
                    }
                }
                .padding(Metrics.gutter)
            }

            Divider()

            HStack {
                Toggle(
                    "Ask me about the document before translating",
                    isOn: $model.preferences.askClarifyingQuestions
                )
                .font(.callout)
                Spacer(minLength: 12)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(Metrics.rowInset)
        }
        .frame(width: 600, height: 560)
    }

    // MARK: - Asked for

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(
                "Instructions — asked for",
                "Handed to the translator and the reviewer as prose. Nothing "
                    + "mechanical enforces these. “Keep personal names in "
                    + "Chinese.” “This is a court filing — keep it formal.”"
            )

            if model.brief.instructions.isEmpty {
                Text("No instructions on this document.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(
                Array(model.brief.instructions.enumerated()),
                id: \.offset
            ) { index, instruction in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "text.quote")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(instruction)
                    Spacer(minLength: 8)
                    Button {
                        model.removeInstruction(at: index)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Remove this instruction")
                }
                .font(.callout)
            }

            HStack {
                TextField("Add an instruction", text: $draft.instruction)
                    .onSubmit(addInstruction)
                Button("Add", action: addInstruction)
                    .disabled(!canAddInstruction)
            }

            if !model.brief.instructions.isEmpty {
                Button("Use these for every document from now on") {
                    model.makeInstructionsStanding()
                }
                .buttonStyle(.link)
                .font(.caption)
                .help(
                    "Copies them into Settings, where standing instructions "
                        + "can be seen and removed"
                )
            }
        }
    }

    // MARK: - Checked

    private var glossary: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(
                "Particular words — checked",
                "A promise the app can keep. Where a block contains the word "
                    + "and the English does not do what you asked, the block "
                    + "is marked."
            )

            if model.brief.glossary.isEmpty {
                Text("No pinned words on this document.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(model.brief.glossary) { term in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "checkmark.seal")
                        .font(.caption)
                        .foregroundStyle(.green)
                    Text(term.instruction)
                    Spacer(minLength: 8)
                    Button {
                        model.remove(term)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Remove this pinned word")
                }
                .font(.callout)
            }

            HStack(spacing: 8) {
                TextField("Word in the source", text: $draft.term)
                    .frame(width: 150)
                Picker("", selection: $draft.keepAsWritten) {
                    Text("keep as written").tag(true)
                    Text("always translate as").tag(false)
                }
                .labelsHidden()
                .fixedSize()
                if !draft.keepAsWritten {
                    TextField("English", text: $draft.rendering)
                        .frame(width: 130)
                }
                Button("Add", action: addTerm)
                    .disabled(!canAddTerm)
            }

            if model.preferences.preference == .fastest,
               !model.brief.instructions.isEmpty {
                // The one combination where half this sheet quietly does
                // nothing, said on the sheet rather than left to be
                // discovered from the result.
                NoteLabel(
                    "The fastest translator is chosen in Settings, and it "
                        + "cannot read instructions. Pinned words are still "
                        + "checked afterwards; the instructions above are "
                        + "not acted on while translating.",
                    tone: .caution
                )
            }
        }
    }

    private var questions: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(
                "What you told the app about this document",
                "Your answers to the questions it asked before it started."
            )
            ForEach(model.brief.settledQuestions) { settled in
                VStack(alignment: .leading, spacing: 1) {
                    Text(settled.question)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(settled.answer)
                        .font(.callout)
                }
            }
        }
    }

    // MARK: - Adding

    private var canAddInstruction: Bool {
        !draft.instruction
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
    }

    private var canAddTerm: Bool {
        let term = draft.term.trimmingCharacters(in: .whitespacesAndNewlines)
        if term.isEmpty { return false }
        if draft.keepAsWritten { return true }
        return !draft.rendering.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty
    }

    private func addInstruction() {
        model.addInstruction(draft.instruction)
        draft.instruction = ""
    }

    private func addTerm() {
        if draft.keepAsWritten {
            model.keepAsWritten(draft.term)
        } else {
            model.alwaysRender(draft.term, as: draft.rendering)
        }
        draft.term = ""
        draft.rendering = ""
    }
}
