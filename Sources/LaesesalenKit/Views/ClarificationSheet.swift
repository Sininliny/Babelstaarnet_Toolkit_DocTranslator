import Combine
import DocCore
import SwiftUI

/// The questions the app asks before it translates.
///
/// It is worth being careful about the shape of this sheet. It interrupts
/// someone who dropped a file expecting an answer, so it has to earn the
/// interruption: at most three questions, each with the phrase from their own
/// document that raised it, each answerable in one click, and every one of
/// them skippable. "I'm not sure" is a real answer and is always available —
/// forcing a guess would turn the app's uncertainty into the reader's
/// decision, which is worse than not asking.
///
/// That last promise was made in this comment and in the README, and the
/// sheet did not keep it: there was a "Skip all" button for the whole sheet,
/// and no way at all to say "I don't know" to one question and answer the
/// other two. Every question now carries it, and choosing it is distinct from
/// never having looked at the question — the button along the bottom says
/// which of the two the reader is about to do.
struct ClarificationSheet: View {
    @ObservedObject var model: AppModel
    @StateObject private var state = Choices()

    final class Choices: ObservableObject {
        @Published var chosen: [UUID: ClarificationOption] = [:]
        /// Questions the reader has explicitly declined to answer, kept apart
        /// from the ones they have not reached.
        @Published var unsure: Set<UUID> = []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelHeader(
                "Before translating",
                "These change the English. Answer what you know — “I'm not "
                    + "sure” is a real answer."
            )

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    ForEach(
                        Array(model.questions.enumerated()),
                        id: \.element.id
                    ) { index, question in
                        questionView(question, number: index + 1)
                    }
                }
                .padding(Metrics.gutter)
            }

            Divider()

            HStack(spacing: 10) {
                Button("Skip all") { model.skipQuestions() }
                Text(progress)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer(minLength: 12)
                Button(answered == 0 ? "Translate without answering" : "Translate") {
                    submit()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(Metrics.rowInset)
        }
        .frame(width: 580, height: 500)
    }

    private var answered: Int {
        state.chosen.count
    }

    private var progress: String {
        "\(answered) of \(model.questions.count) answered"
    }

    private func questionView(
        _ question: ClarificationQuestion,
        number: Int
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(number).")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Text(question.question)
                    .font(.callout.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
            }

            // The phrase from their own document that raised it. Without
            // this, a question about a term is a question about nothing the
            // reader can place.
            if let evidence = question.evidence, !evidence.isEmpty {
                Text(evidence)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.leading, 8)
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(Color.secondary.opacity(0.35))
                            .frame(width: 2)
                    }
                    .padding(.leading, 18)
            }

            VStack(alignment: .leading, spacing: 2) {
                ForEach(question.options) { option in
                    optionRow(
                        question: question,
                        label: option.label,
                        isChosen: state.chosen[question.id]?.id == option.id
                    ) {
                        state.chosen[question.id] = option
                        state.unsure.remove(question.id)
                    }
                }
                optionRow(
                    question: question,
                    label: "I'm not sure",
                    isChosen: state.unsure.contains(question.id),
                    isDecline: true
                ) {
                    state.chosen[question.id] = nil
                    state.unsure.insert(question.id)
                }
            }
            .padding(.leading, 18)
        }
        .accessibilityElement(children: .contain)
    }

    private func optionRow(
        question: ClarificationQuestion,
        label: String,
        isChosen: Bool,
        isDecline: Bool = false,
        choose: @escaping () -> Void
    ) -> some View {
        Button(action: choose) {
            HStack(spacing: 8) {
                Image(
                    systemName: isChosen
                        ? "largecircle.fill.circle"
                        : "circle"
                )
                .foregroundStyle(
                    isChosen ? Color.accentColor : Color.secondary
                )
                Text(label)
                    .foregroundStyle(isDecline ? .secondary : .primary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isChosen ? [.isSelected] : [])
    }

    private func submit() {
        let answers = model.questions.compactMap { question -> SettledQuestion? in
            guard let option = state.chosen[question.id] else { return nil }
            return SettledQuestion(
                question: question.question,
                answer: option.label,
                guidance: option.guidance
            )
        }
        model.answer(answers)
    }
}
