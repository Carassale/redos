import Foundation

public struct ChatMessage: Codable, Sendable, Equatable {
    public let role: String
    public let content: String

    public static func system(_ content: String) -> Self { Self(role: "system", content: content) }
    public static func user(_ content: String) -> Self { Self(role: "user", content: content) }
    public static func assistant(_ content: String) -> Self { Self(role: "assistant", content: content) }
}

public struct ChatResponse: Decodable, Sendable {
    public struct Message: Decodable, Sendable {
        public let content: String
    }

    public struct TokenLogprob: Decodable, Sendable {
        public struct Alternative: Decodable, Sendable {
            public let token: String
            public let logprob: Double
        }

        public let token: String
        public let logprob: Double
        public let topLogprobs: [Alternative]?

        enum CodingKeys: String, CodingKey {
            case token, logprob
            case topLogprobs = "top_logprobs"
        }
    }

    public let message: Message
    public let logprobs: [TokenLogprob]?
}

public protocol ChatCompleting: Sendable {
    func chat(
        _ messages: [ChatMessage], format: JSONValue?, maxTokens: Int?, topLogprobs: Int?
    ) async throws -> ChatResponse

    /// Loads the model in memory ahead of the first request.
    func preload() async
}

/// Minimal client for Ollama's native `/api/chat`, with thinking disabled.
public struct OllamaClient: ChatCompleting, ModelListing {
    public let baseURL: URL
    public let model: String
    public let keepAlive: String
    private let session: URLSession

    public init(
        baseURL: URL = URL(string: "http://127.0.0.1:11434")!,
        model: String,
        keepAlive: String = "30m",
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.model = model
        self.keepAlive = keepAlive
        self.session = session
    }

    public func chat(
        _ messages: [ChatMessage], format: JSONValue? = nil, maxTokens: Int? = nil, topLogprobs: Int? = nil
    ) async throws -> ChatResponse {
        let body = OllamaChatRequest(
            model: model,
            messages: messages,
            keepAlive: keepAlive,
            options: .init(temperature: 0, numPredict: maxTokens),
            format: format,
            logprobs: topLogprobs == nil ? nil : true,
            topLogprobs: topLogprobs
        )
        let data = try await post("api/chat", body: JSONEncoder().encode(body))
        return try JSONDecoder().decode(ChatResponse.self, from: data)
    }

    public func preload() async {
        let body = try? JSONEncoder().encode(["model": model, "keep_alive": keepAlive])
        _ = try? await post("api/generate", body: body ?? Data())
    }

    public func listModels() async throws -> [String] {
        struct Tags: Decodable {
            struct Model: Decodable {
                let name: String
            }

            let models: [Model]
        }
        let request = try HTTP.request(baseURL.appending(path: "api/tags"), headers: [:])
        let data = try await HTTP.send(request, service: "Ollama", session: session)
        return try JSONDecoder().decode(Tags.self, from: data).models.map(\.name).sorted()
    }

    private func post(_ path: String, body: Data) async throws -> Data {
        var request = URLRequest(url: baseURL.appending(path: path), timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw SystemOneError.unavailable(String(localized: "Ollama is not reachable at \(baseURL.absoluteString)"))
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw SystemOneError.http(status) }
        return data
    }
}

private struct OllamaChatRequest: Encodable {
    struct Options: Encodable {
        let temperature: Double
        let numPredict: Int?

        enum CodingKeys: String, CodingKey {
            case temperature
            case numPredict = "num_predict"
        }
    }

    let model: String
    let messages: [ChatMessage]
    let stream = false
    let think = false
    let keepAlive: String
    let options: Options
    let format: JSONValue?
    let logprobs: Bool?
    let topLogprobs: Int?

    enum CodingKeys: String, CodingKey {
        case model, messages, stream, think, options, format, logprobs
        case keepAlive = "keep_alive"
        case topLogprobs = "top_logprobs"
    }
}
