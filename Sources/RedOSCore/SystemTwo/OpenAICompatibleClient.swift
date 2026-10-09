import Foundation

/// OpenAI Chat Completions API; also used for Google Gemini through its OpenAI-compatible endpoint.
public struct OpenAICompatibleClient: ChatCompleting, ModelListing {
    public let service: String
    public let baseURL: URL
    public let model: String
    private let apiKey: String
    private let session: URLSession

    public init(service: String, baseURL: URL, apiKey: String, model: String, session: URLSession = .shared) {
        self.service = service
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.session = session
    }

    private struct Completion: Decodable {
        struct Choice: Decodable {
            let message: ChatResponse.Message
        }

        let choices: [Choice]
    }

    private struct Models: Decodable {
        struct Model: Decodable {
            let id: String
        }

        let data: [Model]
    }

    public func chat(
        _ messages: [ChatMessage], format: JSONValue?, maxTokens: Int?, topLogprobs: Int?
    ) async throws -> ChatResponse {
        var body: [String: JSONValue] = [
            "model": .string(model),
            "messages": .array(messages.map(\.jsonValue)),
        ]
        if format != nil {
            body["response_format"] = .object(["type": .string("json_object")])
        }
        let request = try HTTP.request(
            baseURL.appending(path: "chat/completions"), method: "POST", headers: authorization, body: .object(body)
        )
        let data = try await HTTP.send(request, service: service, session: session)
        guard let message = try JSONDecoder().decode(Completion.self, from: data).choices.first?.message else {
            throw ProviderError.emptyResponse
        }
        return ChatResponse(message: message, logprobs: nil)
    }

    public func preload() async {}

    public func listModels() async throws -> [String] {
        let request = try HTTP.request(baseURL.appending(path: "models"), headers: authorization)
        let data = try await HTTP.send(request, service: service, session: session)
        // Gemini lists ids as "models/<name>".
        return try JSONDecoder().decode(Models.self, from: data).data
            .map { $0.id.hasPrefix("models/") ? String($0.id.dropFirst("models/".count)) : $0.id }
            .sorted()
    }

    private var authorization: [String: String] {
        ["Authorization": "Bearer \(apiKey)"]
    }
}
