import Foundation

/// What an engine is being asked to do. The same model may fill several of
/// these roles, and the interface shows which one is filling which.
public enum EngineRole: String, Sendable, CaseIterable, Identifiable {
    case pageReader
    case adjudicator
    case translator
    case reviewer

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .pageReader: return "Reading the page"
        case .adjudicator: return "Settling disagreements"
        case .translator: return "Translating"
        case .reviewer: return "Reviewing"
        }
    }
}

/// Whether an engine can be used right now, and if not, what the user would
/// have to do about it.
///
/// The reason matters more than the flag. "Apple Intelligence is off" is
/// something a person can fix in thirty seconds; an app that only says
/// "unavailable" has turned a settings toggle into a dead end.
public struct EngineStatus: Sendable, Identifiable, Equatable {
    public enum State: Sendable, Equatable {
        case ready
        /// Present, but something must happen first.
        case needsSetup(String, remedy: String)
        /// Not present on this machine at all.
        case unavailable(String)

        public var isReady: Bool { self == .ready }
    }

    public var id: String { engineName + role.rawValue }
    public let engineName: String
    public let role: EngineRole
    public let state: State
    /// Whether this engine is one of the models that came with macOS.
    public let isBuiltIn: Bool

    public init(
        engineName: String,
        role: EngineRole,
        state: State,
        isBuiltIn: Bool
    ) {
        self.engineName = engineName
        self.role = role
        self.state = state
        self.isBuiltIn = isBuiltIn
    }
}

/// A model that takes instructions and text and answers with text.
///
/// Deliberately not a chat API. Nothing in this pipeline holds a conversation:
/// every call is one block, with one instruction, and no history — which is
/// also what keeps a page of someone's contract out of the context of the next
/// page's request.
public protocol TextAgent: Sendable {
    var engineName: String { get }
    var isBuiltIn: Bool { get }
    func status(for role: EngineRole) async -> EngineStatus
    func answer(
        instructions: String,
        prompt: String,
        expecting: AnswerShape
    ) async throws -> String
}

/// What kind of answer the caller needs, so an engine that can constrain its
/// output does, and one that cannot at least knows how long to be.
public enum AnswerShape: Sendable, Equatable {
    /// Prose, roughly this many characters.
    case prose(approximately: Int)
    /// One of a fixed set of words, and nothing else.
    case choice([String])
}

/// A dedicated translator: source in, target out, with no instructions to
/// misread and no opportunity to answer a different question.
public protocol TranslationEngine: Sendable {
    var engineName: String { get }
    var isBuiltIn: Bool { get }
    func status(for languages: LanguagePair) async -> EngineStatus
    func translate(
        _ text: String,
        languages: LanguagePair
    ) async throws -> String
    /// Whole blocks at once, where an engine can do better than a loop.
    func translate(
        batch: [String],
        languages: LanguagePair
    ) async throws -> [String]
}

extension TranslationEngine {
    /// The general case: one call per block. Overridden by engines with a
    /// real batch API, which is most of the saving on a long document.
    public func translate(
        batch: [String],
        languages: LanguagePair
    ) async throws -> [String] {
        var results: [String] = []
        results.reserveCapacity(batch.count)
        for text in batch {
            results.append(try await translate(text, languages: languages))
        }
        return results
    }
}

public enum AgentFailure: LocalizedError {
    case notAvailable(String)
    case emptyAnswer(String)
    case refused(String)

    public var errorDescription: String? {
        switch self {
        case .notAvailable(let detail):
            return detail
        case .emptyAnswer(let engine):
            return "\(engine) returned nothing."
        case .refused(let detail):
            return detail
        }
    }
}
