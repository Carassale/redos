import Foundation

/// Client for a Jev-compatible `POST /v1/systemone` endpoint: Jev, OpenJev (e.g. Codiv) or Ollama with a
/// decision model (e.g. tev1).
public struct JevHTTPSystemOne: SystemOne, JevDeciding {
    public static let codivURL = URL(string: "https://api.codiv.ai")!

    public let baseURL: URL
    public let model: String
    private let apiKey: String?
    private let session: URLSession

    public init(baseURL: URL, model: String = "jev-latest", apiKey: String? = nil, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
        self.session = session
    }

    private struct Response: Decodable {
        let answers: [String: JevAnswer]
    }

    static func body(state: String, questions: [String: JevQuestion], model: String) -> JSONValue {
        .object([
            "model": .string(model),
            "keep_alive": .string("30m"),
            "state": .string(state),
            "questions": .object(questions.mapValues(\.json)),
        ])
    }

    static func answers(from data: Data) throws -> [String: JevAnswer] {
        try JSONDecoder().decode(Response.self, from: data).answers
    }

    static func answer(from data: Data) throws -> JevChoiceAnswer {
        guard let answer = try answers(from: data)["action"], let choice = answer.choice else {
            throw SystemOneError.noDecision
        }
        return JevChoiceAnswer(choice: choice, probabilities: answer.probabilities, confidence: answer.confidence ?? 0)
    }

    public func decide(state: String, questions: [String: JevQuestion]) async throws -> [String: JevAnswer] {
        // Decisions take well under a second: a slow service falls back to the local model sooner.
        var request = URLRequest(url: baseURL.appending(path: "v1/systemone"), timeoutInterval: 8)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(Self.body(state: state, questions: questions, model: model))

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw SystemOneError.unavailable(String(localized: "Jev is not reachable at \(baseURL.absoluteString)"))
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw SystemOneError.http(status) }
        return try Self.answers(from: data)
    }

    public func choose(_ question: JevChoiceQuestion, state: String) async throws -> JevChoiceAnswer {
        let answers = try await decide(
            state: state, questions: ["action": .choice(instructions: question.instructions, options: question.options)]
        )
        guard let answer = answers["action"], let choice = answer.choice else { throw SystemOneError.noDecision }
        return JevChoiceAnswer(choice: choice, probabilities: answer.probabilities, confidence: answer.confidence ?? 0)
    }
}
