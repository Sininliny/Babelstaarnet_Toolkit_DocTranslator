import DocCore
import Foundation
import FoundationModels

/// The model that came with macOS, asked one question at a time.
///
/// This is the app's default for every role a language model fills:
/// adjudicating between two readings, translating, and reviewing. It needs no
/// download, no server, no configuration, and — the point of the whole
/// project — no network. `SystemLanguageModel` runs on this machine.
///
/// One thing this file must never do is reach for
/// `PrivateCloudComputeLanguageModel`, which is in the same framework and
/// sends the prompt to Apple's servers. `Scripts/test-layout.sh` fails the
/// build if that name appears anywhere in `Sources`, because a privacy
/// guarantee enforced by remembering is not enforced.
public struct SystemTextAgent: TextAgent {
    public let engineName = "Apple on-device model"
    public let isBuiltIn = true
    private let temperature: Double

    /// Low, not zero. Translation has more than one right answer and a
    /// completely greedy decode is where a small model's repetition loops
    /// come from — which `TextIntegrity` would then catch, having spent the
    /// call.
    public init(temperature: Double = 0.2) {
        self.temperature = temperature
    }

    /// Guardrails set to the transformation profile, which is what Apple
    /// provides it for. Translating a document is a content *transformation*:
    /// the words are the user's own, already in front of them, and a court
    /// summons or a medical letter is exactly the kind of document someone
    /// needs translated and exactly the kind the general profile is most
    /// likely to decline.
    private var model: SystemLanguageModel {
        SystemLanguageModel(
            useCase: .general,
            guardrails: .permissiveContentTransformations
        )
    }

    public func status(for role: EngineRole) async -> EngineStatus {
        EngineStatus(
            engineName: engineName,
            role: role,
            state: Self.state(of: model),
            isBuiltIn: true
        )
    }

    static func state(of model: SystemLanguageModel) -> EngineStatus.State {
        switch model.availability {
        case .available:
            return .ready
        case .unavailable(.appleIntelligenceNotEnabled):
            return .needsSetup(
                "Apple Intelligence is turned off.",
                remedy: "Turn it on in System Settings → Apple Intelligence "
                    + "& Siri."
            )
        case .unavailable(.modelNotReady):
            return .needsSetup(
                "The system model is still downloading.",
                remedy: "Leave the Mac on power and connected; it finishes "
                    + "on its own."
            )
        case .unavailable(.deviceNotEligible):
            return .unavailable(
                "This Mac cannot run Apple's on-device model."
            )
        case .unavailable:
            return .unavailable("The system model is unavailable.")
        }
    }

    /// True when the model claims to handle the pair. Worth asking before a
    /// page rather than after: a model asked to work in a language it does
    /// not support does not fail, it produces plausible nonsense.
    public func supports(_ languages: LanguagePair) -> Bool {
        let model = model
        return model.supportsLocale(Locale(identifier: languages.source.identifier))
            && model.supportsLocale(Locale(identifier: languages.target.identifier))
    }

    public func answer(
        instructions: String,
        prompt: String,
        expecting: AnswerShape
    ) async throws -> String {
        let model = model
        guard case .ready = Self.state(of: model) else {
            throw AgentFailure.notAvailable(
                "The on-device model is not available."
            )
        }

        // A fresh session per call, with no transcript. Nothing in this
        // pipeline is a conversation, and a session that accumulated pages
        // would put page one's contents into page two's context for no
        // benefit and a longer prompt.
        let session = LanguageModelSession(model: model) { instructions }
        let options = GenerationOptions(
            temperature: temperature,
            maximumResponseTokens: Self.tokenBudget(for: expecting)
        )

        do {
            let response = try await session.respond(
                to: prompt,
                options: options
            )
            let text = response.content.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !text.isEmpty else {
                throw AgentFailure.emptyAnswer(engineName)
            }
            if case .choice(let allowed) = expecting {
                return Self.nearest(text, in: allowed) ?? text
            }
            return text
        } catch let error as LanguageModelSession.GenerationError {
            throw Self.translate(error)
        }
    }

    /// Roughly four characters to a token, with headroom, because a
    /// translation that stops mid-sentence reads as a model failure and is a
    /// budget failure.
    static func tokenBudget(for shape: AnswerShape) -> Int {
        switch shape {
        case .prose(let characters):
            return max(128, min(4_096, characters / 2))
        case .choice:
            return 16
        }
    }

    /// A model told to answer with one of three words will sometimes answer
    /// with one of them inside a sentence. Recovering the word is better than
    /// discarding the call.
    static func nearest(_ text: String, in allowed: [String]) -> String? {
        let lowered = text.lowercased()
        if let exact = allowed.first(where: { $0.lowercased() == lowered }) {
            return exact
        }
        return allowed.first { lowered.contains($0.lowercased()) }
    }

    static func translate(
        _ error: LanguageModelSession.GenerationError
    ) -> AgentFailure {
        switch error {
        case .guardrailViolation:
            return .refused(
                "The on-device model declined this block. Its contents may "
                    + "have tripped a safety filter."
            )
        case .exceededContextWindowSize:
            return .refused(
                "This block is too long for the on-device model to take in "
                    + "one piece."
            )
        default:
            return .refused(error.localizedDescription)
        }
    }
}
