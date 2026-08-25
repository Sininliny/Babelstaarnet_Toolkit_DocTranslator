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
struct ClarificationSheet: View {
    @ObservedObject var model: AppModel
    @StateObject private var state = Choices()

    final class Choices: ObservableObject {
        @Published var chosen: [UUID: ClarificationOption] = [:]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Before translating")
                    .font(.headline)
                Text(
                    "These change the English. Answer what you know and skip "
                        + "the rest."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            .padding(18)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    ForEach(model.questions) { question in
                        questionView(question)
                    }
                }
                .padding(18)
            }

            Divider()

            HStack {
                Button("Skip all") { model.skipQuestions() }
                Spacer()
                Button("Translate") { submit() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(width: 560, height: 460)
    }

    private func questionView(_ question: ClarificationQuestion) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(question.question)
                .font(.system(size: 14, weight: .medium))

            if let evidence = question.evidence, !evidence.isEmpty {
                Text(evidence)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 8)
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(Color.secondary.opacity(0.35))
                            .frame(width: 2)
                    }
            }

            ForEach(question.options) { option in
                Button {
                    state.chosen[question.id] = option
                } label: {
                    HStack(spacing: 8) {
                        Image(
                            systemName: state.chosen[question.id]?.id == option.id
                                ? "largecircle.fill.circle"
                                : "circle"
                        )
                        .foregroundStyle(
                            state.chosen[question.id]?.id == option.id
                                ? Color.accentColor
                                : Color.secondary
                        )
                        Text(option.label)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
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
