import Foundation

public struct ResolvedPlan: Sendable, Equatable {
    public let input: String
    public let steps: [ActionRequest]
}

/// System Two output: actions to run, or a short reply when nothing should be run.
public struct PlanResult: Sendable, Equatable {
    public let steps: [ActionRequest]
    public let answer: String?

    public init(steps: [ActionRequest], answer: String? = nil) {
        self.steps = steps
        self.answer = answer
    }
}

/// System Two: handles what System One cannot (multi-step tasks, questions, unclear commands).
public protocol Planning: Sendable {
    func plan(_ input: String, registry: ActionRegistry) async throws -> PlanResult
}

public enum PlanError: Error, Equatable, LocalizedError {
    case tooManySteps(Int)
    case unreadable

    public var errorDescription: String? {
        switch self {
        case .tooManySteps(let count): String(localized: "The plan has too many steps (\(count)).")
        case .unreadable: String(localized: "System Two replied with an unreadable plan.")
        }
    }
}

/// Works with any provider: local Ollama, Copilot, OpenAI, Claude, Gemini.
public struct ModelPlanner: Planning {
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

        let steps: [Step]?
        let answer: String?
    }

    public func plan(_ input: String, registry: ActionRegistry) async throws -> PlanResult {
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
                    Reply with JSON only: {"steps": [{"action": "<id>", "arguments": {"<parameter>": <value>}}]}
                    Example: "apri Note e scrivi ciao" -> {"steps": [{"action": "app.open", "arguments": \
                    {"name": "Notes"}}, {"action": "text.type", "arguments": {"text": "ciao"}}]}
                    If the user asks a question or chats, or part of the request cannot be done with these actions,
                    reply {"steps": [], "answer": "<one or two sentences in the user's language>"}.
                    Never invent real-time facts (weather, news, prices, time): say you cannot access them.
                    """),
                .user(input),
            ],
            format: .string("json"),
            maxTokens: 512,
            topLogprobs: nil
        )
        guard let json = JSONText.firstObject(in: response.message.content),
              let plan = try? JSONDecoder().decode(Plan.self, from: Data(json.utf8))
        else { throw PlanError.unreadable }
        let steps = plan.steps ?? []
        guard steps.count <= Self.maxSteps else { throw PlanError.tooManySteps(steps.count) }
        let requests = steps.map { step in
            let arguments = registry.action(for: step.action).map {
                ArgumentExtractor.arguments(from: step.arguments ?? [:], for: $0, input: input)
            }
            return ActionRequest(step.action, arguments ?? [:])
        }
        let answer = plan.answer?.trimmingCharacters(in: .whitespacesAndNewlines)
        return PlanResult(steps: requests, answer: answer?.isEmpty == false ? answer : nil)
    }
}
