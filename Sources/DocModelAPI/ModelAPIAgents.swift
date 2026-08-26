import DocCore
import DocPrivacy
import Foundation

/// A user-run model server in the text roles.
public struct ModelAPITextAgent: TextAgent {
    public let engineName: String
    public let isBuiltIn = false
    private let client: ModelAPIClient
    private let model: String
    private let temperature: Double

    public init(
        client: ModelAPIClient,
        model: String,
        dialect: ModelAPIConfiguration.Dialect,
        temperature: Double = 0.2
    ) {
        self.client = client
        self.model = model
        self.temperature = temperature
        self.engineName = "\(model) via \(dialect.displayName)"
    }

    public func status(for role: EngineRole) async -> EngineStatus {
        let state: EngineStatus.State
        do {
            let installed = try await client.installedModels()
            if installed.isEmpty {
                state = .needsSetup(
                    "The server is running but has no models.",
                    remedy: "Pull a model on the server and try again."
                )
            } else if installed.contains(where: { $0.hasPrefix(model) }) {
                state = .ready
            } else {
                state = .needsSetup(
                    "\(model) is not on the server.",
                    remedy: "It has: " + installed.prefix(4)
                        .joined(separator: ", ")
                )
            }
        } catch {
            state = .needsSetup(
                error.localizedDescription,
                remedy: "Start the server, then check again."
            )
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
        let answer = try await client.chat(
            model: model,
            system: instructions,
            user: prompt,
            temperature: temperature,
            maximumTokens: Self.tokenBudget(for: expecting)
        )
        // Reasoning models emit their working before the answer, in tags the
        // server does not always strip. The answer is what comes after, and
        // the same removal serves every engine here — a server running Qwen3
        // and the app's own copy of it produce the same thing.
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

    static func tokenBudget(for shape: AnswerShape) -> Int {
        switch shape {
        case .prose(let characters):
            return max(256, min(8_192, characters))
        case .choice:
            // Not sixteen: a reasoning model spends its budget thinking and
            // then has nothing left to answer with.
            return 512
        }
    }
}

/// A user-run vision model as the second reader.
public struct ModelAPIVisionReader: PageTranscriber {
    public let reader: PageReader = .visionLanguageModel
    public let engineName: String
    private let client: ModelAPIClient
    private let model: String
    private let longSide: Int

    public init(
        client: ModelAPIClient,
        model: String,
        dialect: ModelAPIConfiguration.Dialect,
        longSide: Int = 1_536
    ) {
        self.client = client
        self.model = model
        self.longSide = longSide
        self.engineName = "\(model) via \(dialect.displayName)"
    }

    public func transcribe(
        _ page: PageImage,
        language: SourceLanguage
    ) async throws -> PageReading {
        let started = Date()
        let image = ImageScaling.scaled(page.image, longSide: longSide)
            ?? page.image
        let answer = try await client.chat(
            model: model,
            system: AgentPrompts.transcriptionInstructions(for: language),
            user: AgentPrompts.transcriptionRequest(for: language),
            image: image,
            temperature: 0,
            maximumTokens: 4_096
        )
        return PageReading(
            reader: reader,
            pageIndex: page.index,
            blocks: AgentPrompts.blocks(
                fromTranscription: AgentPrompts.stripReasoning(answer),
                pageIndex: page.index,
                language: language
            ),
            seconds: Date().timeIntervalSince(started)
        )
    }
}
