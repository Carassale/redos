public enum PolicyDecision: Sendable, Equatable {
    case allow
    case confirm
    case deny
}

public struct Policy: Sendable {
    public var autoApproveUpTo: RiskLevel
    public var disabledActions: Set<String>

    public init(autoApproveUpTo: RiskLevel = .moderate, disabledActions: Set<String> = []) {
        self.autoApproveUpTo = autoApproveUpTo
        self.disabledActions = disabledActions
    }

    public func decide(for action: any Action) -> PolicyDecision {
        if disabledActions.contains(action.id) { return .deny }
        if action.risk == .dangerous || action.risk > autoApproveUpTo { return .confirm }
        return .allow
    }
}
