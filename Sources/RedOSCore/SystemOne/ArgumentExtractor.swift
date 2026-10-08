import Foundation

/// Second stage after the decision: fills the chosen action's parameters. Uses plain JSON mode because a
/// per-request JSON schema grammar costs ~1 s in Ollama; ActionRegistry still validates types strictly.
public struct ArgumentExtractor: Sendable {
    private let client: any ChatCompleting

    public init(client: any ChatCompleting) {
        self.client = client
    }

    public func arguments(for action: any Action, input: String) async throws -> ActionArguments {
        guard !action.parameters.isEmpty else { return [:] }
        let parameterList = action.parameters
            .map { "- \($0.name)\(Self.typeHint($0))\($0.isRequired ? "" : " (optional)"): \($0.description)" }
            .joined(separator: "\n")
        let response = try await client.chat(
            [
                .system("""
                    Extract the arguments of the action "\(action.id)" (\(action.summary)) from the user's command.
                    Omit optional parameters that are not mentioned. Reply with a JSON object only.
                    Parameters:
                    \(parameterList)
                    """),
                .user(input),
            ],
            format: .string("json"),
            maxTokens: 256,
            topLogprobs: nil
        )
        let values = try JSONDecoder().decode([String: JSONValue].self, from: Data(response.message.content.utf8))
        return values.reduce(into: ActionArguments()) { result, pair in
            switch pair.value {
            case .string(let text) where !text.isEmpty: result[pair.key] = text
            case .number(let number):
                result[pair.key] = number == number.rounded() ? String(Int(number)) : String(number)
            case .bool(let flag): result[pair.key] = String(flag)
            default: break
            }
        }
    }

    private static func typeHint(_ parameter: ActionParameter) -> String {
        switch parameter.kind {
        case .string: " (string)"
        case .integer: " (integer)"
        case .oneOf(let options): " (one of: \(options.joined(separator: ", ")))"
        }
    }
}
