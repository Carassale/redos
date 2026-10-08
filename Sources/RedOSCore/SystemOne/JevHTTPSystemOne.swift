import Foundation

/// Client for a Jev-compatible `POST /v1/systemone` endpoint: LocalJev (`make localjev-run`) or Jev itself.
public struct JevHTTPSystemOne: SystemOne {
    public let baseURL: URL
    private let apiKey: String?
    private let session: URLSession

    public init(baseURL: URL, apiKey: String? = nil, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.session = session
    }

    private struct Response: Decodable {
        let answers: [String: JevChoiceAnswer]
    }

    static func body(for question: JevChoiceQuestion, state: String) -> JSONValue {
        let criteria = Dictionary(
            uniqueKeysWithValues: question.options.map { ($0.label, JSONValue.string($0.description)) }
        )
        return .object([
            "model": .string("jev-latest"),
            "state": .string(state),
            "questions": .object([
                "action": .object([
                    "type": .string("choice"),
                    "instructions": .string(question.instructions),
                    "criteria": .object(criteria),
                ])
            ]),
        ])
    }

    static func answer(from data: Data) throws -> JevChoiceAnswer {
        guard let answer = try JSONDecoder().decode(Response.self, from: data).answers["action"] else {
            throw SystemOneError.noDecision
        }
        return answer
    }

    public func choose(_ question: JevChoiceQuestion, state: String) async throws -> JevChoiceAnswer {
        var request = URLRequest(url: baseURL.appending(path: "v1/systemone"), timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(Self.body(for: question, state: state))

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw SystemOneError.unavailable(String(localized: "Jev is not reachable at \(baseURL.absoluteString)"))
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw SystemOneError.http(status) }
        return try Self.answer(from: data)
    }
}
