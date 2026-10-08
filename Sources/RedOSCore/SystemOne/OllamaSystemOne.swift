import Foundation

/// Jev-style decision read from the model's next-token log-probabilities: one generated token, real
/// probabilities (not self-reported), ~1 s on an M3 with a 4B model.
public struct OllamaSystemOne: SystemOne {
    private static let letters = "ABCDEFGHIJKLMNOPQRSTUVWXYZ".map(String.init)
    private let client: any ChatCompleting

    public init(client: any ChatCompleting) {
        self.client = client
    }

    public func choose(_ question: JevChoiceQuestion, state: String) async throws -> JevChoiceAnswer {
        guard question.options.count <= Self.letters.count else { throw SystemOneError.tooManyOptions }
        let letters = Array(Self.letters.prefix(question.options.count))
        let menu = zip(letters, question.options)
            .map { "\($0)) \($1.label): \($1.description)" }
            .joined(separator: "\n")
        let response = try await client.chat(
            [
                .system("\(question.instructions)\nOptions:\n\(menu)\nAnswer with the option letter only."),
                .user(state),
            ],
            format: nil,
            maxTokens: 1,
            topLogprobs: 20
        )

        var mass: [String: Double] = [:]
        for alternative in response.logprobs?.first?.topLogprobs ?? [] {
            let token = alternative.token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let index = letters.firstIndex(of: token) else { continue }
            mass[question.options[index].label, default: 0] += exp(alternative.logprob)
        }
        return try JevChoiceAnswer(normalizing: mass, labels: question.options.map(\.label))
    }
}
