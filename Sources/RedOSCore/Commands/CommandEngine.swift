import Foundation

public enum Resolution: Sendable, Equatable {
    case unrecognized
    case invalid(ActionRequest, ActionError)
    case denied(ActionRequest)
    case ready(ActionRequest, needsConfirmation: Bool)
}

/// Turns user input into validated, policy-checked and audited action executions.
public struct CommandEngine: Sendable {
    static let redacted = "‹redacted›"

    public let registry: ActionRegistry
    public var parser: FastPathParser
    public var policy: Policy
    private let permissions: any PermissionChecking
    private let audit: any AuditLogging

    public init(
        registry: ActionRegistry,
        parser: FastPathParser = FastPathParser(),
        policy: Policy = Policy(),
        permissions: any PermissionChecking = SystemPermissionChecker(),
        audit: any AuditLogging
    ) {
        self.registry = registry
        self.parser = parser
        self.policy = policy
        self.permissions = permissions
        self.audit = audit
    }

    public func resolve(_ input: String) async -> Resolution {
        guard let request = parser.parse(input) else {
            await record(input, nil, .unrecognized)
            return .unrecognized
        }
        let action: any Action
        do {
            action = try registry.validate(request)
        } catch {
            await record(input, request, .invalid, error: error)
            return .invalid(request, error)
        }
        switch policy.decide(for: action) {
        case .deny:
            await record(input, request, .denied)
            return .denied(request)
        case .confirm:
            return .ready(request, needsConfirmation: true)
        case .allow:
            return .ready(request, needsConfirmation: false)
        }
    }

    public func cancel(_ request: ActionRequest, input: String) async {
        await record(input, request, .cancelled)
    }

    public func execute(_ request: ActionRequest, input: String) async -> Result<Void, ActionError> {
        do {
            let action = try registry.validate(request)
            if let missing = action.requiredPermissions.first(where: { permissions.status(of: $0) != .granted }) {
                throw ActionError.permissionMissing(missing)
            }
            try await action.run(request.arguments)
            await record(input, request, .completed)
            return .success(())
        } catch {
            let actionError = error as? ActionError ?? .failed(error.localizedDescription)
            await record(input, request, .failed, error: actionError)
            return .failure(actionError)
        }
    }

    private func record(
        _ input: String, _ request: ActionRequest?, _ outcome: AuditEntry.Outcome, error: ActionError? = nil
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
            actionID: request?.actionID,
            arguments: arguments,
            risk: action?.risk,
            outcome: outcome,
            error: error?.errorDescription
        ))
    }
}
