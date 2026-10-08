public enum PolicyDecision: Sendable, Equatable {
    case allow
    case confirm
    case deny
}

public struct Policy: Sendable {
    public var autoApproveUpTo: RiskLevel
    public var disabledActions: Set<String>
    /// Model-routed actions above `.safe` need confirmation below this probability.
    public var modelAutoRunConfidence: Double

    public init(
        autoApproveUpTo: RiskLevel = .moderate, disabledActions: Set<String> = [], modelAutoRunConfidence: Double = 0.85
    ) {
        self.autoApproveUpTo = autoApproveUpTo
        self.disabledActions = disabledActions
        self.modelAutoRunConfidence = modelAutoRunConfidence
    }

    /// `confidence` is nil for deterministic (fast path) requests.
    public func decide(for action: any Action, confidence: Double? = nil) -> PolicyDecision {
        if disabledActions.contains(action.id) { return .deny }
        if action.risk == .dangerous || action.risk > autoApproveUpTo { return .confirm }
        if let confidence, action.risk > .safe, confidence < modelAutoRunConfidence { return .confirm }
        return .allow
    }
}
