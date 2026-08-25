import CoreGraphics
import DocCore
import DocPrivacy
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Talks to a local model server, in whichever of the two dialects it speaks.
///
/// Requests are assembled with `JSONSerialization` rather than `Codable`
/// because the message field is a string in one dialect and an array of typed
/// parts in the other, and expressing that with encoders costs more code than
/// it saves.
public actor ModelAPIClient {
    private let session: PrivateSession
    private let configuration: ModelAPIConfiguration

    public init(
        configuration: ModelAPIConfiguration,
        ledger: PrivacyLedger
    ) async {
        self.configuration = configuration
        self.session = await PrivateSession(ledger: ledger)
    }

    /// The models the server has, which is what turns "connection refused"
    /// into a sentence the user can act on.
    public func installedModels() async throws -> [String] {
        let data = try await session.get(
            configuration.endpoint,
            path: configuration.dialect.listPath
        )
        let json = try JSONSerialization.jsonObject(with: data)
        guard let object = json as? [String: Any] else { return [] }
        switch configuration.dialect {
        case .ollama:
            let models = object["models"] as? [[String: Any]] ?? []
            return models.compactMap { $0["name"] as? String }
        case .openAICompatible:
            let models = object["data"] as? [[String: Any]] ?? []
            return models.compactMap { $0["id"] as? String }
        }
    }

    public func chat(
        model: String,
        system: String,
        user: String,
        image: CGImage? = nil,
        temperature: Double,
        maximumTokens: Int
    ) async throws -> String {
        let body = try request(
            model: model,
            system: system,
            user: user,
            image: image,
            temperature: temperature,
            maximumTokens: maximumTokens
        )
        let data = try await session.post(
            configuration.endpoint,
            path: configuration.dialect.chatPath,
            body: body
        )
        return try answer(from: data)
    }

    private func request(
        model: String,
        system: String,
        user: String,
        image: CGImage?,
        temperature: Double,
        maximumTokens: Int
    ) throws -> Data {
        let encoded = image.flatMap { ImageEncoding.base64PNG($0) }
        var payload: [String: Any] = ["model": model, "stream": false]

        switch configuration.dialect {
        case .ollama:
            var message: [String: Any] = ["role": "user", "content": user]
            if let encoded { message["images"] = [encoded] }
            payload["messages"] = [
                ["role": "system", "content": system],
                message
            ]
            payload["options"] = [
                "temperature": temperature,
                "num_predict": maximumTokens
            ]
        case .openAICompatible:
            var parts: [[String: Any]] = [["type": "text", "text": user]]
            if let encoded {
                parts.append([
                    "type": "image_url",
                    "image_url": ["url": "data:image/png;base64,\(encoded)"]
                ])
            }
            payload["messages"] = [
                ["role": "system", "content": system],
                ["role": "user", "content": parts]
            ]
            payload["temperature"] = temperature
            payload["max_tokens"] = maximumTokens
        }

        return try JSONSerialization.data(withJSONObject: payload)
    }

    private func answer(from data: Data) throws -> String {
        let json = try JSONSerialization.jsonObject(with: data)
        guard let object = json as? [String: Any] else {
            throw AgentFailure.emptyAnswer(configuration.dialect.displayName)
        }
        switch configuration.dialect {
        case .ollama:
            let message = object["message"] as? [String: Any]
            guard let content = message?["content"] as? String else {
                throw AgentFailure.emptyAnswer("Ollama")
            }
            return content
        case .openAICompatible:
            let choices = object["choices"] as? [[String: Any]] ?? []
            let message = choices.first?["message"] as? [String: Any]
            guard let content = message?["content"] as? String else {
                throw AgentFailure.emptyAnswer("the model server")
            }
            return content
        }
    }
}

enum ImageEncoding {
    /// PNG rather than JPEG, deliberately. A JPEG artifact around a hanzi
    /// stroke is exactly the kind of damage that changes which character a
    /// model reads, and the pages are already downscaled before they get
    /// here.
    static func base64PNG(_ image: CGImage) -> String? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return (data as Data).base64EncodedString()
    }
}
