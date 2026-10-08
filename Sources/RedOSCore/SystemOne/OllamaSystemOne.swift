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
        let response = try await client.chat(
            messages(for: question, state: state),
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

    public func transcript(for question: JevChoiceQuestion, state: String, answer: JevChoiceAnswer) -> [ChatMessage] {
        guard let index = question.options.firstIndex(where: { $0.label == answer.choice }),
              index < Self.letters.count
        else { return [] }
        return messages(for: question, state: state) + [.assistant(Self.letters[index])]
    }

    /// The system prompt depends only on the catalog, so Ollama keeps it cached across commands.
    private func messages(for question: JevChoiceQuestion, state: String) -> [ChatMessage] {
        let menu = zip(Self.letters, question.options)
            .map { "\($0)) \($1.label): \($1.description)" }
            .joined(separator: "\n")
        return [
            .system("\(question.instructions)\nOptions:\n\(menu)\nAnswer with the option letter only."),
            .user(state),
        ]
    }
}
