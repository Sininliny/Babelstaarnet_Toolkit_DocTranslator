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
            Text("Translation brief")
                .font(.headline)
                .padding(18)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    instructions
                    glossary
                    questions
                }
                .padding(18)
            }

            Divider()

            HStack {
                Toggle(
                    "Ask me about the document before translating",
                    isOn: $model.preferences.askClarifyingQuestions
                )
                .font(.callout)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(width: 580, height: 520)
    }

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Instructions")
                .font(.system(size: 13, weight: .semibold))
            Text(
                "Anything you would tell a human translator. “Keep personal "
                    + "names in Chinese.” “This is a court filing — keep it "
                    + "formal.”"
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            ForEach(Array(model.brief.instructions.enumerated()), id: \.offset) {
                index, instruction in
                HStack(alignment: .top, spacing: 6) {
                    Text("•")
                    Text(instruction)
                    Spacer()
                    Button {
                        model.removeInstruction(at: index)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                .font(.callout)
            }

            HStack {
                TextField("Add an instruction", text: $draft.instruction)
                    .onSubmit(addInstruction)
                Button("Add", action: addInstruction)
                    .disabled(draft.instruction.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ).isEmpty)
            }

            if !model.brief.instructions.isEmpty {
                Button("Use these for every document from now on") {
                    model.makeInstructionsStanding()
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        }
    }

    private var glossary: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Particular words")
                .font(.system(size: 13, weight: .semibold))
            Text(
                "These are checked. If a block contains the word and the "
                    + "English does not do what you asked, the block is marked."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            ForEach(model.brief.glossary) { term in
                HStack(alignment: .top, spacing: 6) {
                    Text(term.instruction)
                    Spacer()
                    Button {
                        model.remove(term)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
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
        }
    }

    private var questions: some View {
        Group {
            if !model.brief.settledQuestions.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("What you told the app about this document")
                        .font(.system(size: 13, weight: .semibold))
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
        }
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
