#if MLXEngine

import CoreGraphics
import DocCore
import Foundation
import MLXLMCommon

/// The same model in the text roles: adjudicating, translating, reviewing,
/// and asking the reader what it cannot settle for itself.
///
/// One model for all four, and for reading the page as well. A vision-language
/// model is a language model with an image encoder bolted on, so the text
/// roles cost nothing extra — and the alternative is a second download, a
/// second couple of gigabytes resident, and two models swapping in and out of
/// memory on every block.
public struct MLXTextAgent: TextAgent {
    public var engineName: String { name }
    public let isBuiltIn = false
    private let store: MLXModelStore
    private let name: String
    private let temperature: Float

    public init(
        store: MLXModelStore,
        name: String,
        temperature: Float = 0.2
    ) {
        self.store = store
        self.name = name
        self.temperature = temperature
    }

    public func status(for role: EngineRole) async -> EngineStatus {
        let state: EngineStatus.State
        switch await store.currentState() {
        case .ready, .onDisk:
            state = .ready
        case .notFetched:
            let model = await store.model
            state = .needsSetup(
                "\(model.displayName) has not been downloaded yet.",
                remedy: "Get it once (\(model.approximateSize)); it runs on "
                    + "this Mac from then on."
            )
        case .fetching(let fraction):
            state = .needsSetup(
                "Downloading — \(Int(fraction * 100))%.",
                remedy: "It only happens once."
            )
        case .loading:
            state = .needsSetup(
                "Loading into memory.",
                remedy: "A few seconds."
            )
        case .failed(let problem):
            state = .unavailable(problem)
        }
        return EngineStatus(
            engineName: engineName,
            role: role,
            state: state,
            isBuiltIn: false
        )
    }

    public func answer(
        instructions: String,
        prompt: String,
        expecting: AnswerShape
    ) async throws -> String {
        let container = try await store.prepare()
        let model = await store.model
        let session = ChatSession(
            container,
            instructions: Self.instructions(instructions, for: model),
            generateParameters: GenerateParameters(
                maxTokens: Self.tokenBudget(
                    for: expecting,
                    reasoning: model.reasonsByDefault
                ),
                temperature: Self.temperature(self.temperature, for: expecting)
            ),
            // No image in a text call, so the processing is nominal — but
            // it is set rather than nil, because nil is the value that
            // silently drops media when there is any.
            processing: UserInput.Processing(
                resize: CGSize(width: 1_024, height: 1_024)
            )
        )

        let answer = try await session.respond(to: prompt)
        let text = AgentPrompts.stripWrapping(answer)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw AgentFailure.emptyAnswer(engineName)
        }
        if case .choice(let allowed) = expecting {
            let lowered = text.lowercased()
            return allowed.first { lowered.contains($0.lowercased()) } ?? text
        }
        return text
    }

    /// A one-word answer is asked for greedily; prose is not, because a
    /// completely greedy decode is where a small model's repetition loops
    /// come from.
    static func temperature(
        _ base: Float,
        for shape: AnswerShape
    ) -> Float {
        if case .choice = shape { return 0 }
        return base
    }

    /// A model that reasons before answering is told not to.
    ///
    /// The switch is the one its own chat template accepts, and it is put in
    /// the instructions rather than the prompt so it cannot end up in the
    /// text being translated. Where the template ignores it,
    /// `AgentPrompts.stripReasoning` still keeps the reasoning out of the
    /// answer and the enlarged budget still leaves room to reach one — this
    /// is the cheap half of a belt and braces, not the only half.
    static func instructions(
        _ instructions: String,
        for model: LocalModelSpec
    ) -> String {
        guard let quiet = model.thinkingSwitch else { return instructions }
        return instructions + "\n" + quiet
    }

    /// How much room the answer gets.
    ///
    /// A one-word answer needs eight tokens — unless the model spends its
    /// budget reasoning first, in which case eight tokens produce no answer
    /// at all and the adjudicator silently stops adjudicating. So a model
    /// that reasons is given room to reason and *then* answer, and the
    /// reasoning is thrown away afterwards.
    static func tokenBudget(
        for shape: AnswerShape,
        reasoning: Bool = false
    ) -> Int {
        let headroom = reasoning ? 512 : 0
        switch shape {
        case .prose(let characters):
            return max(256, min(4_096, characters)) + headroom
        case .choice:
            return 8 + headroom
        }
    }
}

#endif
