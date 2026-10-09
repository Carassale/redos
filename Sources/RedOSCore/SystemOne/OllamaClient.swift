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
        // Long prompts (diagrams) need a larger context than Ollama's default; short ones keep the cached slot.
        let characters = messages.reduce(0) { $0 + $1.content.count }
        let needed = characters / 3 + (maxTokens ?? 1024)
        let numCtx = characters > 12_000 ? min(32_768, (needed / 4096 + 1) * 4096) : nil
        let body = OllamaChatRequest(
            model: model,
            messages: messages,
            keepAlive: keepAlive,
            options: .init(temperature: 0, numPredict: maxTokens, numCtx: numCtx),
            format: format,
            logprobs: topLogprobs == nil ? nil : true,
            topLogprobs: topLogprobs
        )
        let data: Data
        do {
            data = try await post("api/chat", body: JSONEncoder().encode(body), timeout: numCtx == nil ? 120 : 900)
        } catch SystemOneError.http(501) where format != nil {
            // Some models (e.g. qwen3.5) reject structured output: callers parse JSON from plain text.
            return try await chat(messages, format: nil, maxTokens: maxTokens, topLogprobs: topLogprobs)
        }
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

    /// Downloads a model; `progress` receives the completed fraction while Ollama reports sizes.
    public func pull(_ name: String, progress: @Sendable (Double) async -> Void) async throws {
        struct Update: Decodable {
            let total: Double?
            let completed: Double?
            let error: String?
        }
        var request = URLRequest(url: baseURL.appending(path: "api/pull"), timeoutInterval: 3600)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["model": name])
        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            throw SystemOneError.unavailable(String(localized: "Ollama is not reachable at \(baseURL.absoluteString)"))
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw SystemOneError.http(status) }
        for try await line in bytes.lines {
            guard let update = try? JSONDecoder().decode(Update.self, from: Data(line.utf8)) else { continue }
            if let error = update.error { throw SystemOneError.unavailable(error) }
            if let total = update.total, total > 0, let completed = update.completed {
                await progress(completed / total)
            }
        }
    }

    private func post(_ path: String, body: Data, timeout: TimeInterval = 120) async throws -> Data {
        var request = URLRequest(url: baseURL.appending(path: path), timeoutInterval: timeout)
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
        let numCtx: Int?

        enum CodingKeys: String, CodingKey {
            case temperature
            case numPredict = "num_predict"
            case numCtx = "num_ctx"
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
