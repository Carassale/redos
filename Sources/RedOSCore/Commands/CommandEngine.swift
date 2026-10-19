import Foundation

public struct ResolvedCommand: Sendable, Equatable {
    public let input: String
    public let request: ActionRequest
    public let route: AuditEntry.Route
    /// Probability of the chosen action; nil for deterministic fast-path matches.
    public let confidence: Double?
}

public enum Resolution: Sendable, Equatable {
    case unrecognized
    case unavailable(String)
    case invalid(ActionRequest, ActionError)
    case denied(ActionRequest)
    case ready(ResolvedCommand, needsConfirmation: Bool)
    /// Fast-path plans follow the policy; model-written plans run unattended only if every step is `safe`.
    case plan(ResolvedPlan, needsConfirmation: Bool)
    /// System Two replied with text instead of actions (questions, things it cannot do).
    case answer(String)
    /// The task needs to look at the screen between steps: run it with `runAgent`.
    case agent(String)
    /// The question needs the web: run it with `runResearch`.
    case research(String, query: String)
    /// A diagram or chart to draw: run it with `runDiagram`.
    case diagram(String, description: String)
    /// A report or request for the developer, to open for the user to review.
    case feedback(Feedback)
    /// Start (true) or stop taking notes of a call.
    case takeNotes(Bool)
    /// A briefing about the day, put together by the app (calendar, reminders, battery).
    case briefing
}

/// Progress callback for the HUD: 1-based step number and the action about to run.
public typealias StepHandler = @MainActor @Sendable (_ step: Int, _ request: ActionRequest) -> Void

/// Turns user input into validated, policy-checked and audited action executions.
public struct CommandEngine: Sendable {
    static let redacted = "‹redacted›"

    public let registry: ActionRegistry
    public var parser: FastPathParser
    public var policy: Policy
    private let router: (any CommandRouting)?
    let planner: (any Planning)?
    let assistant: (any Planning)?
    let agent: (any Acting)?
    let observer: (any ScreenObserving)?
    let routines: RoutineStore?
    let memory: MemoryStore?
    public let conversation: Conversation?
    let writer: (any ChatCompleting)?
    let web: (any WebResearching)?
    let researcher: ResearchAgent?
    let designer: DiagramDesigner?
    let corrector: CorrectionClassifier?
    let behaviors: BehaviorStore?
    /// How to talk (see `Persona`), before the rules.
    let persona: String?
    /// Saved call minutes: emailed, turned into reminders, asked about.
    let meetings: MeetingStore?
    private let permissions: any PermissionChecking
    private let audit: any AuditLogging

    /// `planner` handles multi-step requests (fast, local); `assistant` questions and unclear commands
    /// (any provider, defaults to `planner`); `agent` and `observer` tasks that need to see the screen;
    /// `writer` requests about the selected text; `web` quick currency conversions; `researcher` questions
    /// that need current information.
    public init(
        registry: ActionRegistry,
        parser: FastPathParser = FastPathParser(),
        policy: Policy = Policy(),
        router: (any CommandRouting)? = nil,
        planner: (any Planning)? = nil,
        assistant: (any Planning)? = nil,
        agent: (any Acting)? = nil,
        observer: (any ScreenObserving)? = nil,
        routines: RoutineStore? = nil,
        memory: MemoryStore? = nil,
        conversation: Conversation? = nil,
        writer: (any ChatCompleting)? = nil,
        web: (any WebResearching)? = nil,
        researcher: ResearchAgent? = nil,
        designer: DiagramDesigner? = nil,
        corrector: CorrectionClassifier? = nil,
        behaviors: BehaviorStore? = nil,
        persona: String? = nil,
        meetings: MeetingStore? = nil,
        permissions: any PermissionChecking = SystemPermissionChecker(),
        audit: any AuditLogging
    ) {
        self.registry = registry
        self.parser = parser
        self.policy = policy
        self.router = router
        self.planner = planner
        self.assistant = assistant
        self.agent = agent
        self.observer = observer
        self.routines = routines
        self.memory = memory
        self.conversation = conversation
        self.writer = writer
        self.web = web
        self.researcher = researcher
        self.designer = designer
        self.corrector = corrector
        self.behaviors = behaviors
        self.persona = persona
        self.meetings = meetings
        self.permissions = permissions
        self.audit = audit
    }

    public func prepare() async {
        await router?.prepare()
    }

    public func resolve(_ input: String) async -> Resolution {
        if let resolution = await resolveWithContext(input) {
            return resolution
        }
        if let request = parser.parse(input) {
            return await check(ResolvedCommand(input: input, request: request, route: .fastPath, confidence: nil))
        }
        if let steps = parser.parsePlan(input) {
            return await check(ResolvedPlan(input: input, steps: steps, route: .fastPath))
        }
        guard let router else {
            await record(input, nil, .unrecognized)
            return .unrecognized
        }
        do {
            await ActivityReporter.report(.understanding)
            let decision = try await router.route(input)
            switch decision {
            case .action(let request, let confidence):
                return await checkSystemOne(request, input: input, confidence: confidence)
            case .noAction(let confidence):
                return await escalate(input, to: assistant ?? planner, guess: nil, confidence: confidence)
            case .multiStep(let confidence):
                return await escalate(input, to: planner, guess: nil, confidence: confidence)
            case .uncertain(let actionID, let confidence):
                return await escalate(
                    input, to: assistant ?? planner, guess: ActionRequest(actionID), confidence: confidence
                )
            case .screenQuestion(let confidence), .screenTask(let confidence), .research(let confidence),
                 .diagram(let confidence):
                return await resolveKind(of: input, decision, confidence: confidence)
            }
        } catch {
            let actionError = ActionError.failed(error.localizedDescription)
            await record(input, nil, .failed, route: .systemOne, error: actionError)
            return .unavailable(error.localizedDescription)
        }
    }

    /// External tools return raw data: as a plan their output is explained, like System Two's.
    private func checkSystemOne(_ request: ActionRequest, input: String, confidence: Double) async -> Resolution {
        if registry.action(for: request.actionID) is MCPToolAction {
            return await check(ResolvedPlan(input: input, steps: [request], route: .systemOne))
        }
        return await check(ResolvedCommand(input: input, request: request, route: .systemOne, confidence: confidence))
    }

    /// Hands the request to System Two (with the remembered facts); without one, System One's verdict is final.
    func escalate(
        _ input: String, to planner: (any Planning)?, guess: ActionRequest?, confidence: Double
    ) async -> Resolution {
        guard let planner else {
            await record(input, guess, .unrecognized, route: .systemOne, confidence: confidence)
            return .unrecognized
        }
        let result: PlanResult
        do {
            await ActivityReporter.report(.thinking)
            result = try await planner.plan(await withContext(input), registry: registry)
        } catch {
            await record(input, nil, .failed, route: .systemTwo, error: .failed(error.localizedDescription))
            return .unavailable(error.localizedDescription)
        }
        guard !result.steps.isEmpty else {
            if result.look, let resolution = await resolveLook(input) {
                return resolution
            }
            if result.needsScreen, agent != nil, observer != nil {
                return .agent(input)
            }
            if let query = result.research, researcher != nil {
                return .research(input, query: query)
            }
            if let description = result.diagram, designer != nil {
                return .diagram(input, description: description)
            }
            await record(input, nil, result.answer == nil ? .unrecognized : .answered, route: .systemTwo)
            return result.answer.map(Resolution.answer) ?? .unrecognized
        }
        return await check(ResolvedPlan(input: input, steps: PlanSimplifier.simplify(result.steps), route: .systemTwo))
    }

    func check(_ plan: ResolvedPlan) async -> Resolution {
        var needsConfirmation = false
        for step in plan.steps {
            let command = ResolvedCommand(input: plan.input, request: step, route: plan.route, confidence: nil)
            switch await check(command) {
            case .ready(_, let confirm):
                let risk = registry.action(for: step.actionID)?.risk ?? .dangerous
                needsConfirmation = needsConfirmation || confirm || (plan.route == .systemTwo && risk > .safe)
            case let other:
                return other
            }
        }
        return .plan(plan, needsConfirmation: needsConfirmation)
    }

    private func check(_ command: ResolvedCommand) async -> Resolution {
        let action: any Action
        do {
            action = try registry.validate(command.request)
        } catch {
            await record(command, .invalid, error: error)
            return .invalid(command.request, error)
        }
        switch policy.decide(for: action, confidence: command.confidence) {
        case .deny:
            await record(command, .denied)
            return .denied(command.request)
        case .confirm:
            return .ready(command, needsConfirmation: true)
        case .allow:
            return .ready(command, needsConfirmation: false)
        }
    }

    public func execute(_ command: ResolvedCommand) async -> Result<String?, ActionError> {
        do {
            try Task.checkCancellation()
            let action = try registry.validate(command.request)
            if let missing = action.requiredPermissions.first(where: { permissions.status(of: $0) != .granted }) {
                throw ActionError.permissionMissing(missing)
            }
            var output: String?
            if let reporting = action as? any ReportingAction {
                output = try await reporting.report(command.request.arguments)
            } else {
                try await action.run(command.request.arguments)
            }
            await record(command, .completed)
            return .success(output)
        } catch is CancellationError {
            await record(command, .cancelled)
            return .failure(.cancelled)
        } catch {
            let actionError = error as? ActionError ?? .failed(error.localizedDescription)
            await record(command, actionError == .cancelled ? .cancelled : .failed, error: actionError)
            return .failure(actionError)
        }
    }

    func record(_ command: ResolvedCommand, _ outcome: AuditEntry.Outcome, error: ActionError? = nil) async {
        await record(
            command.input, command.request, outcome, route: command.route, confidence: command.confidence, error: error
        )
    }

    func record(
        _ input: String,
        _ request: ActionRequest?,
        _ outcome: AuditEntry.Outcome,
        route: AuditEntry.Route? = nil,
        confidence: Double? = nil,
        error: ActionError? = nil
    ) async {
        let action = request.flatMap { registry.action(for: $0.actionID) }
        let sensitive = Set(action?.parameters.filter(\.isSensitive).map(\.name) ?? [])
        let arguments = (request?.arguments ?? [:]).reduce(into: [String: String]()) { result, pair in
            result[pair.key] = sensitive.contains(pair.key) ? Self.redacted : pair.value
        }
        let containsSensitive = request?.arguments.keys.contains(where: sensitive.contains) ?? false
        await audit.record(AuditEntry(
            date: .now,
            input: containsSensitive ? Self.redacted : input,
            route: route,
            confidence: confidence,
            actionID: request?.actionID,
            arguments: arguments,
            risk: action?.risk,
            outcome: outcome,
            error: error?.errorDescription
        ))
    }
}

extension CommandEngine {
    /// Runs the steps in order and stops at the first failure or when the task is cancelled.
    /// Returns the outputs of reporting actions, if any.
    public func execute(_ plan: ResolvedPlan, onStep: StepHandler? = nil) async -> Result<String?, ActionError> {
        var outputs: [String] = []
        var usedMCP = false
        for (index, command) in commands(of: plan).enumerated() {
            if index > 0 {
                // Let the previous step settle (window focus, page load) before the next one.
                try? await Task.sleep(for: .milliseconds(400))
            }
            await onStep?(index + 1, command.request)
            switch await execute(command) {
            case .success(let output):
                if let output { outputs.append(output) }
                usedMCP = usedMCP || registry.action(for: command.request.actionID) is MCPToolAction
            case .failure(let error):
                return .failure(error)
            }
        }
        guard !outputs.isEmpty else { return .success(nil) }
        let text = outputs.joined(separator: "\n\n")
        return .success(usedMCP ? await explain(text, for: plan.input) : text)
    }

    func commands(of plan: ResolvedPlan) -> [ResolvedCommand] {
        plan.steps.map { ResolvedCommand(input: plan.input, request: $0, route: plan.route, confidence: nil) }
    }
}
