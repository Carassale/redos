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
}

/// Turns user input into validated, policy-checked and audited action executions.
public struct CommandEngine: Sendable {
    static let redacted = "‹redacted›"

    public let registry: ActionRegistry
    public var parser: FastPathParser
    public var policy: Policy
    private let router: (any CommandRouting)?
    private let permissions: any PermissionChecking
    private let audit: any AuditLogging

    public init(
        registry: ActionRegistry,
        parser: FastPathParser = FastPathParser(),
        policy: Policy = Policy(),
        router: (any CommandRouting)? = nil,
        permissions: any PermissionChecking = SystemPermissionChecker(),
        audit: any AuditLogging
    ) {
        self.registry = registry
        self.parser = parser
        self.policy = policy
        self.router = router
        self.permissions = permissions
        self.audit = audit
    }

    public func prepare() async {
        await router?.prepare()
    }

    public func resolve(_ input: String) async -> Resolution {
        if let request = parser.parse(input) {
            return await check(ResolvedCommand(input: input, request: request, route: .fastPath, confidence: nil))
        }
        guard let router else {
            await record(input, nil, .unrecognized)
            return .unrecognized
        }
        do {
            switch try await router.route(input) {
            case .action(let request, let confidence):
                return await check(
                    ResolvedCommand(input: input, request: request, route: .systemOne, confidence: confidence)
                )
            case .noAction(let confidence):
                await record(input, nil, .unrecognized, route: .systemOne, confidence: confidence)
            case .uncertain(let actionID, let confidence):
                await record(input, ActionRequest(actionID), .unrecognized, route: .systemOne, confidence: confidence)
            }
            return .unrecognized
        } catch {
            let actionError = ActionError.failed(error.localizedDescription)
            await record(input, nil, .failed, route: .systemOne, error: actionError)
            return .unavailable(error.localizedDescription)
        }
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

    public func cancel(_ command: ResolvedCommand) async {
        await record(command, .cancelled)
    }

    public func execute(_ command: ResolvedCommand) async -> Result<Void, ActionError> {
        do {
            let action = try registry.validate(command.request)
            if let missing = action.requiredPermissions.first(where: { permissions.status(of: $0) != .granted }) {
                throw ActionError.permissionMissing(missing)
            }
            try await action.run(command.request.arguments)
            await record(command, .completed)
            return .success(())
        } catch {
            let actionError = error as? ActionError ?? .failed(error.localizedDescription)
            await record(command, .failed, error: actionError)
            return .failure(actionError)
        }
    }

    private func record(_ command: ResolvedCommand, _ outcome: AuditEntry.Outcome, error: ActionError? = nil) async {
        await record(
            command.input, command.request, outcome, route: command.route, confidence: command.confidence, error: error
        )
    }

    private func record(
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
