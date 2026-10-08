public enum RouteDecision: Sendable, Equatable {
    case action(ActionRequest, confidence: Double)
    /// No single action fits: a question, a conversation or a multi-step task (System Two territory).
    case noAction(confidence: Double)
    case uncertain(actionID: String, confidence: Double)
}

public protocol CommandRouting: Sendable {
    func prepare() async
    func route(_ input: String) async throws -> RouteDecision
}

public struct SystemOneRouter: CommandRouting {
    public static let noneLabel = "none"

    private let registry: ActionRegistry
    private let systemOne: any SystemOne
    private let extractor: ArgumentExtractor
    private let warmUp: any ChatCompleting
    private let threshold: Double

    public init(
        registry: ActionRegistry,
        systemOne: any SystemOne,
        extractor: ArgumentExtractor,
        warmUp: any ChatCompleting,
        threshold: Double = 0.6
    ) {
        self.registry = registry
        self.systemOne = systemOne
        self.extractor = extractor
        self.warmUp = warmUp
        self.threshold = threshold
    }

    var question: JevChoiceQuestion {
        let actions = registry.all.map { JevOption(label: $0.id, description: $0.summary) }
        let none = JevOption(
            label: Self.noneLabel,
            description: "None of the above: a question, a conversation, or a task that needs several steps"
                + " or an action that is not listed."
        )
        return JevChoiceQuestion(
            instructions: "Pick the single action that fulfils the user's command on their Mac.",
            options: actions + [none]
        )
    }

    public func prepare() async {
        await warmUp.preload()
    }

    public func route(_ input: String) async throws -> RouteDecision {
        let answer = try await systemOne.choose(question, state: input)
        if answer.choice == Self.noneLabel {
            return .noAction(confidence: answer.probability)
        }
        guard answer.probability >= threshold, let action = registry.action(for: answer.choice) else {
            return .uncertain(actionID: answer.choice, confidence: answer.probability)
        }
        let arguments = try await extractor.arguments(for: action, input: input)
        return .action(ActionRequest(action.id, arguments), confidence: answer.probability)
    }
}
