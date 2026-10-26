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
            case .diagram: "Draw a diagram, flowchart, timeline, chart or graph, also with an explanation."
            }
        }
    }

    public static let noneLabel = "none"
    /// A read-only external tool (MCP) picked at least this surely runs alone (wrong picks seen at 0.91).
    public static let externalToolThreshold = 0.95
    /// Below that, when external tools hold at least this much of the action answer, the likeliest fast ones
    /// (up to `lookUpTools`, each above `lookUpMinimum`) run together and System Two only writes the answer.
    public static let lookUpMass = 0.5
    public static let lookUpMinimum = 0.1
    public static let lookUpTools = 2

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
        var questions: [String: JevQuestion] = [
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
        let sources = quickSources
        if !sources.isEmpty {
            questions["source"] = .choice(
                instructions: "Which of these tools of the user's company finds what the request asks about"
                    + " (its clients, projects, people, documents)?",
                options: sources.map { JevOption(label: $0.id, description: $0.summary) } + [JevOption(
                    label: Self.noneLabel,
                    description: "None: general knowledge, conversation, news or web, or an action on the Mac."
                )]
            )
        }
        return questions
    }

    /// External tools that are read-only, fast and take something from the request: safe to run on a guess.
    private var quickSources: [MCPToolAction] {
        registry.all.compactMap { $0 as? MCPToolAction }
            .filter { $0.risk == .safe && !$0.isSlow && !$0.parameters.isEmpty }
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
        if let tools = await externalTools(answers["source"], kind: kind, kindConfidence: confidence, input: input) {
            return tools
        }
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

    /// Questions for the company's knowledge tools run them without System Two's plan (it only writes the
    /// answer), unless Jev is sure the request is of another kind. Asked apart from the action question, where
    /// the slow assistant tools draw most of the probability.
    private func externalTools(
        _ answer: JevAnswer?, kind: Kind, kindConfidence: Double, input: String
    ) async -> RouteDecision? {
        let other: Set<Kind> = [.steps, .screenTask, .screenQuestion, .currentInfo, .diagram]
        guard let answer, let extractor, !(other.contains(kind) && kindConfidence >= threshold) else { return nil }
        let sources = Dictionary(uniqueKeysWithValues: quickSources.map { ($0.id, $0) })
        let candidates = answer.probabilities
            .compactMap { id, probability in sources[id].map { (tool: $0, probability: probability) } }
            .sorted { $0.probability > $1.probability }
        let mass = candidates.reduce(0) { $0 + $1.probability }
        guard mass >= Self.lookUpMass, let best = candidates.first else { return nil }
        let chosen = best.probability >= max(threshold, Self.externalToolThreshold)
            ? [best.tool]
            : candidates.filter { $0.probability >= Self.lookUpMinimum }.prefix(Self.lookUpTools).map(\.tool)
        let requests = await withTaskGroup(of: (Int, ActionRequest?).self) { group in
            for (index, tool) in chosen.enumerated() {
                group.addTask {
                    guard let arguments = try? await extractor.arguments(for: tool, input: input) else {
                        return (index, nil)
                    }
                    let request = ActionRequest(tool.id, arguments)
                    return (index, (try? registry.validate(request)) == nil ? nil : request)
                }
            }
            var requests: [Int: ActionRequest] = [:]
            for await (index, request) in group { requests[index] = request }
            return chosen.indices.compactMap { requests[$0] }
        }
        return requests.isEmpty ? nil : .lookUp(requests, confidence: min(mass, 1))
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
        let request = ActionRequest(action.id, arguments)
        return SystemOneRouter.refine(request, registry: registry, confidence: answer.probability)
    }
}
