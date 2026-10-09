import Foundation

/// Anthropic Messages API (Claude).
public struct AnthropicClient: ChatCompleting, ModelListing {
    public let model: String
    private let apiKey: String
    private let baseURL: URL
    private let session: URLSession

    public init(
        apiKey: String,
        model: String,
        baseURL: URL = URL(string: "https://api.anthropic.com/v1")!,
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.model = model
        self.baseURL = baseURL
        self.session = session
    }

    private struct Reply: Decodable {
        struct Block: Decodable {
            let type: String
            let text: String?
        }

        let content: [Block]
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
        var system = messages.filter { $0.role == "system" }.map(\.content).joined(separator: "\n\n")
        if format != nil {
            system += "\n\nReply with a single JSON object only."
        }
        let body: JSONValue = .object([
            "model": .string(model),
            "max_tokens": .number(Double(maxTokens ?? 1024)),
            "system": .string(system),
            "messages": .array(messages.filter { $0.role != "system" }.map(\.jsonValue)),
        ])
        let request = try HTTP.request(
            baseURL.appending(path: "messages"), method: "POST", headers: headers, body: body
        )
        let data = try await HTTP.send(request, service: "Anthropic", session: session)
        let text = try JSONDecoder().decode(Reply.self, from: data).content.compactMap(\.text).joined()
        guard !text.isEmpty else { throw ProviderError.emptyResponse }
        return ChatResponse(message: .init(content: text), logprobs: nil)
    }

    public func preload() async {}

    public func listModels() async throws -> [String] {
        let request = try HTTP.request(baseURL.appending(path: "models"), headers: headers)
        let data = try await HTTP.send(request, service: "Anthropic", session: session)
        return try JSONDecoder().decode(Models.self, from: data).data.map(\.id)
    }

    private var headers: [String: String] {
        ["x-api-key": apiKey, "anthropic-version": "2023-06-01"]
    }
}
