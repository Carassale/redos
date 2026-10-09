import Foundation

public struct ResolvedPlan: Sendable, Equatable {
    public let input: String
    public let steps: [ActionRequest]
}

/// System Two: turns a multi-step request into an ordered list of catalog actions.
public protocol Planning: Sendable {
    func plan(_ input: String, registry: ActionRegistry) async throws -> [ActionRequest]
}

public enum PlanError: Error, Equatable, LocalizedError {
    case tooManySteps(Int)

    public var errorDescription: String? {
        switch self {
        case .tooManySteps(let count): String(localized: "The plan has too many steps (\(count)).")
        }
    }
}

public struct OllamaPlanner: Planning {
    public static let maxSteps = 6
    private let client: any ChatCompleting

    public init(client: any ChatCompleting) {
        self.client = client
    }

    private struct Plan: Decodable {
        struct Step: Decodable {
            let action: String
            let arguments: [String: JSONValue]?
        }

        let steps: [Step]
    }

    public func plan(_ input: String, registry: ActionRegistry) async throws -> [ActionRequest] {
        let catalog = registry.all.map { action in
            let parameters = action.parameters
                .map { "\($0.name)\(ArgumentExtractor.typeHint($0))\($0.isRequired ? "" : " optional")" }
                .joined(separator: ", ")
            return "- \(action.id)(\(parameters)): \(action.summary)"
        }.joined(separator: "\n")
        let response = try await client.chat(
            [
                .system("""
                    You automate a Mac. Break the user's request into the shortest ordered list of these actions:
                    \(catalog)
                    Use only these actions and parameters, and only the steps the user asked for.
                    A website for a named browser is one url.open step with the app argument.
                    If any part of the request cannot be done with them, reply {"steps": []}.
                    Reply with JSON only: {"steps": [{"action": "<id>", "arguments": {"<parameter>": <value>}}]}
                    Example: "apri Note e scrivi ciao" -> {"steps": [{"action": "app.open", "arguments": \
                    {"name": "Notes"}}, {"action": "text.type", "arguments": {"text": "ciao"}}]}
                    """),
                .user(input),
            ],
            format: .string("json"),
            maxTokens: 512,
            topLogprobs: nil
        )
        let plan = try JSONDecoder().decode(Plan.self, from: Data(response.message.content.utf8))
        guard plan.steps.count <= Self.maxSteps else { throw PlanError.tooManySteps(plan.steps.count) }
        return plan.steps.map { step in
            let arguments = registry.action(for: step.action).map {
                ArgumentExtractor.arguments(from: step.arguments ?? [:], for: $0, input: input)
            }
            return ActionRequest(step.action, arguments ?? [:])
        }
    }
}
