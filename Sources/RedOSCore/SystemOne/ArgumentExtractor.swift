import Foundation

/// Second stage after the decision: fills the chosen action's parameters. Uses plain JSON mode because a
/// per-request JSON schema grammar costs ~1 s in Ollama; ActionRegistry still validates types strictly.
public struct ArgumentExtractor: Sendable {
    private let client: any ChatCompleting

    public init(client: any ChatCompleting) {
        self.client = client
    }

    /// With a non-empty `context` (the decision transcript) the request extends it, so the model reuses its cache.
    public func arguments(
        for action: any Action, input: String, context: [ChatMessage] = []
    ) async throws -> ActionArguments {
        guard !action.parameters.isEmpty else { return [:] }
        let parameterList = action.parameters
            .map { "- \($0.name)\(Self.typeHint($0))\($0.isRequired ? "" : " (optional)"): \($0.description)" }
            .joined(separator: "\n")
        let instructions = """
            Extract the arguments of the action "\(action.id)" (\(action.summary)) from the user's command.
            Omit optional parameters that are not mentioned. Reply with a JSON object only.
            Parameters:
            \(parameterList)
            """
        let response = try await client.chat(
            context.isEmpty ? [.system(instructions), .user(input)] : context + [.user(instructions)],
            format: .string("json"),
            maxTokens: 256,
            topLogprobs: nil
        )
        let json = JSONText.firstObject(in: response.message.content) ?? response.message.content
        let values = try JSONDecoder().decode([String: JSONValue].self, from: Data(json.utf8))
        return Self.arguments(from: values, for: action, input: input)
    }

    /// Model JSON to string arguments, dropping integers the user never said.
    static func arguments(from values: [String: JSONValue], for action: any Action, input: String) -> ActionArguments {
        let arguments = values.reduce(into: ActionArguments()) { result, pair in
            switch pair.value {
            case .string(let text) where !text.isEmpty: result[pair.key] = text
            case .number(let number):
                result[pair.key] = number == number.rounded() ? String(Int(number)) : String(number)
            case .bool(let flag): result[pair.key] = String(flag)
            default: break
            }
        }
        // Small models invent coordinates ("center of the screen" -> 0, 0): keep only numbers the user said.
        let spokenNumbers = Set(input.split { !$0.isNumber }.map(String.init))
        return arguments.filter { name, value in
            action.parameters.first { $0.name == name }?.kind != .integer || spokenNumbers.contains(value)
        }
    }

    static func typeHint(_ parameter: ActionParameter) -> String {
        switch parameter.kind {
        case .string: " (string)"
        case .integer: " (integer)"
        case .oneOf(let options): " (one of: \(options.joined(separator: ", ")))"
        case .webAddress: " (web address)"
        }
    }
}
