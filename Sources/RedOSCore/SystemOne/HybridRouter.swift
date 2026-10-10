import Foundation

/// The local model and Jev decide together. The local model is faster (~0.25 s) and more accurate on
/// single actions (eval: 92% with no wrong action run, Jev 89%); Jev recognizes the kind of everything
/// else (eval: 43/43), so questions, screen tasks, research and diagrams skip System Two's planning call.
/// Either one alone still works: offline only the local model answers.
public struct HybridRouter: CommandRouting {
    private let local: any CommandRouting
    private let remote: any CommandRouting

    public init(local: any CommandRouting, remote: any CommandRouting) {
        self.local = local
        self.remote = remote
    }

    public func prepare() async {
        async let first: Void = local.prepare()
        async let second: Void = remote.prepare()
        _ = await (first, second)
    }

    public func route(_ input: String) async throws -> RouteDecision {
        let remoteDecision = Task { try await remote.route(input) }
        let localDecision: RouteDecision
        do {
            localDecision = try await local.route(input)
        } catch {
            return try await remoteDecision.value
        }
        if case .action = localDecision {
            // "di cosa parla questa finestra?" looks like ui.read to the local model, but an answer is meant:
            // a confident Jev verdict that arrives in time wins.
            let verdict = await Self.value(of: remoteDecision, within: .milliseconds(700))
            if let verdict, verdict.overridesAction {
                return verdict
            }
            remoteDecision.cancel()
            return localDecision
        }
        guard let decision = try? await remoteDecision.value else { return localDecision }
        // A single action the local model did not pick confidently: System Two settles it.
        if case .action(let request, let confidence) = decision {
            return .uncertain(actionID: request.actionID, confidence: confidence)
        }
        return decision
    }

    /// The task's result if it arrives within `limit`, without waiting for it afterwards.
    private static func value(of task: Task<RouteDecision, any Error>, within limit: Duration) async -> RouteDecision? {
        let once = ResumeOnce()
        return await withCheckedContinuation { continuation in
            Task { await once.resume(continuation, with: try? await task.value) }
            Task {
                try? await Task.sleep(for: limit)
                await once.resume(continuation, with: nil)
            }
        }
    }
}

private actor ResumeOnce {
    private var resumed = false

    func resume(_ continuation: CheckedContinuation<RouteDecision?, Never>, with value: RouteDecision?) {
        guard !resumed else { return }
        resumed = true
        continuation.resume(returning: value)
    }
}

private extension RouteDecision {
    var overridesAction: Bool {
        switch self {
        case .screenQuestion(let confidence), .research(let confidence), .diagram(let confidence):
            confidence >= 0.9
        default:
            false
        }
    }
}
