import Foundation

/// Routes a command with one Jev request that asks both what kind of request it is and which action fits.
/// Each answer comes with a calibrated probability, so unsure cases still go to System Two.
public struct JevIntentRouter: CommandRouting {
    public enum Kind: String, CaseIterable, Sendable {
        case action
        case steps
        case screenTask = "screen_task"
        case screenQuestion = "screen_question"
        case knowledge
        case currentInfo = "current_info"
        case diagram

        var summary: String {
            switch self {
            case .action: "One single action on the Mac from the action list (open, quit, type, click, scroll…)."
            case .steps: "Several actions in sequence, e.g. open an app and then do something in it."
            case .screenTask:
                "Act on elements of the current screen described by position, order or look"
                    + " (the first result, the second link), filling forms, several clicks inside an app."
            case .screenQuestion:
                "A question about what is shown on screen now (this page, this email, this document,"
                    + " what is written here). Answer by reading the screen, without acting."
            case .knowledge:
                "A question, chat or request for text answered from general knowledge"
                    + " (definitions, history, how-to, jokes, translations, writing)."
            case .currentInfo:
                "A question about anything current or to check online: news, weather, prices,"
                    + " exchange rates, sports results, people and facts that change."
            case .diagram: "Draw a diagram, flowchart, timeline, chart or graph."
            }
        }
    }

    public static let noneLabel = "none"

    private let registry: ActionRegistry
    private let jev: any JevDeciding
    private let extractor: ArgumentExtractor?
    private let warmUp: [any ChatCompleting]
    private let threshold: Double

    /// Without an `extractor` (no local model), actions with arguments go to System Two.
    public init(
        registry: ActionRegistry, jev: any JevDeciding, extractor: ArgumentExtractor?,
        warmUp: [any ChatCompleting] = [], threshold: Double = 0.5
    ) {
        self.registry = registry
        self.jev = jev
        self.extractor = extractor
        self.warmUp = warmUp
        self.threshold = threshold
    }

    public var questions: [String: JevQuestion] {
        [
            "kind": .choice(
                instructions: "What kind of request did the user make to their Mac assistant?",
                options: Kind.allCases.map { JevOption(label: $0.rawValue, description: $0.summary) }
            ),
            "action": .choice(
                instructions: "If the request is one single action on the Mac, which action is it?\n"
                    + "Examples (request -> action):\n" + Self.actionExamples,
                options: registry.all.map { JevOption(label: $0.id, description: $0.summary) }
                    + [JevOption(label: Self.noneLabel, description: "No single action from the list fits.")]
            ),
        ]
    }

    private static var actionExamples: String {
        SystemOneRouter.defaultExamples
            .map { "- \"\($0.command)\" -> \($0.label == SystemOneRouter.multiStepLabel ? noneLabel : $0.label)" }
            .joined(separator: "\n")
    }

    public func prepare() async {
        await withTaskGroup { group in
            for client in warmUp {
                group.addTask { await client.preload() }
            }
        }
    }

    public func route(_ input: String) async throws -> RouteDecision {
        let answers = try await jev.decide(state: "User request: \(input)", questions: questions)
        guard let kindAnswer = answers["kind"], let kind = kindAnswer.choice.flatMap(Kind.init) else {
            throw SystemOneError.noDecision
        }
        let confidence = kindAnswer.probability
        guard confidence >= threshold else { return .noAction(confidence: confidence) }
        switch kind {
        case .action:
            return try await action(answers["action"], input: input)
        case .steps: return .multiStep(confidence: confidence)
        case .screenTask: return .screenTask(confidence: confidence)
        case .screenQuestion: return .screenQuestion(confidence: confidence)
        case .knowledge: return .noAction(confidence: confidence)
        case .currentInfo: return .research(confidence: confidence)
        case .diagram: return .diagram(confidence: confidence)
        }
    }

    private func action(_ answer: JevAnswer?, input: String) async throws -> RouteDecision {
        guard let answer, let choice = answer.choice, choice != Self.noneLabel else {
            return .noAction(confidence: answer?.probability ?? 0)
        }
        guard answer.probability >= threshold, let action = registry.action(for: choice) else {
            return .uncertain(actionID: choice, confidence: answer.probability)
        }
        if action.parameters.isEmpty {
            return .action(ActionRequest(action.id), confidence: answer.probability)
        }
        // System Two can still fill the arguments when the local model is missing or fails.
        guard let extractor, let arguments = try? await extractor.arguments(for: action, input: input) else {
            return .uncertain(actionID: choice, confidence: answer.probability)
        }
        return .action(ActionRequest(action.id, arguments), confidence: answer.probability)
    }
}
