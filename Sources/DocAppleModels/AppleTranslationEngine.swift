import DocCore
import Foundation
import Translation

/// macOS's own translator, running on this machine.
///
/// It is here as a *second opinion*, not as a convenience. A general language
/// model translating a paragraph and a dedicated translation model
/// translating the same paragraph are two engines with different training,
/// different failure modes, and no shared machinery — so where they say the
/// same thing in different words, that is evidence; where one of them drops a
/// clause, the other one still has it.
///
/// It is also the only translator on a Mac where Apple Intelligence is turned
/// off, which is a state a lot of Macs are in.
public actor AppleTranslationEngine: TranslationEngine {
    public nonisolated let engineName = "Apple Translation"
    public nonisolated let isBuiltIn = true

    /// Sessions are per language pair and expensive to build, so one is kept
    /// and reused. `TranslationSession` is not `Sendable`, which is exactly
    /// what an actor is for: it never leaves this one.
    private var session: TranslationSession?
    private var sessionPair: String?

    public init() {}

    public func status(for languages: LanguagePair) async -> EngineStatus {
        let state: EngineStatus.State
        switch await availability(for: languages) {
        case .installed:
            state = .ready
        case .supported:
            state = .needsSetup(
                "\(languages.source.englishName) has not been downloaded yet.",
                remedy: "Læsesalen can fetch it — it is a one-time download "
                    + "from Apple, and translating still happens on this Mac."
            )
        case .unsupported:
            state = .unavailable(
                "macOS does not translate \(languages.displayName)."
            )
        @unknown default:
            state = .unavailable("The translation model is unavailable.")
        }
        return EngineStatus(
            engineName: engineName,
            role: .translator,
            state: state,
            isBuiltIn: true
        )
    }

    public func availability(
        for languages: LanguagePair
    ) async -> LanguageAvailability.Status {
        await LanguageAvailability().status(
            from: Locale.Language(identifier: languages.source.identifier),
            to: Locale.Language(identifier: languages.target.identifier)
        )
    }

    public func translate(
        _ text: String,
        languages: LanguagePair
    ) async throws -> String {
        let results = try await translate(batch: [text], languages: languages)
        guard let first = results.first else {
            throw AgentFailure.emptyAnswer(engineName)
        }
        return first
    }

    /// Whole blocks at once. The framework crosses into the translation
    /// service per call, and a page of forty blocks translated one at a time
    /// spends most of its time in that crossing rather than in the model.
    public func translate(
        batch: [String],
        languages: LanguagePair
    ) async throws -> [String] {
        guard !batch.isEmpty else { return [] }
        let session = try await session(for: languages)
        let requests = batch.enumerated().map { index, text in
            TranslationSession.Request(
                sourceText: text,
                clientIdentifier: String(index)
            )
        }
        let responses = try await session.translations(from: requests)
        // The framework does not promise the order it answers in, and the
        // client identifier is the only thing tying an answer to its block.
        var byIndex: [Int: String] = [:]
        for response in responses {
            guard let identifier = response.clientIdentifier,
                  let index = Int(identifier) else { continue }
            byIndex[index] = response.targetText
        }
        return batch.indices.map { byIndex[$0] ?? "" }
    }

    private func session(
        for languages: LanguagePair
    ) async throws -> TranslationSession {
        let key = "\(languages.source.identifier)>\(languages.target.identifier)"
        if let session, sessionPair == key { return session }

        guard await availability(for: languages) == .installed else {
            throw AgentFailure.notAvailable(
                "\(languages.source.englishName) has not been downloaded for "
                    + "translation yet."
            )
        }
        let fresh = TranslationSession(
            installedSource: Locale.Language(
                identifier: languages.source.identifier
            ),
            target: Locale.Language(identifier: languages.target.identifier)
        )
        session = fresh
        sessionPair = key
        return fresh
    }
}
