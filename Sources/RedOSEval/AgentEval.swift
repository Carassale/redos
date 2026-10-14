import Foundation
import RedOSCore

/// One moment of a screen task: what was done, what the screen shows, and the right next move
/// ("finished", "#n" to press, "scroll_down"/"scroll_up", or "fallback" for System Two: typing, apps, answers).
struct AgentSample: Decodable {
    let task: String
    let history: [String]
    let screen: String
    let expected: String
}

/// Stands in for System Two: marks the steps Jev leaves to it.
private struct FallbackMarker: Acting {
    func next(
        task: String, history: [String], screen: String, screenshot: Screenshot?, registry: ActionRegistry
    ) async throws -> AgentStep {
        .act(ActionRequest("fallback"))
    }
}

private func label(_ step: AgentStep) -> String {
    switch step {
    case .done: "finished"
    case .act(let request) where request.actionID == "scroll": "scroll_\(request.arguments["direction"] ?? "")"
    case .act(let request): request.arguments["target"] ?? request.actionID
    }
}

/// `JevAgent` on recorded screens (eval/agent.jsonl). Stopping early and handing over to System Two are safe;
/// a wrong click is the error that matters.
func evaluateAgent(path: String, jev: JevHTTPSystemOne) async throws {
    let samples = try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n")
        .map { try JSONDecoder().decode(AgentSample.self, from: Data($0.utf8)) }
    let agent = JevAgent(jev: jev, fallback: FallbackMarker())
    print("Agent eval · \(jev.model) · \(samples.count) moments")
    var correct = 0, delegated = 0, early = 0, wrong = 0
    var latencies: [Double] = []
    for sample in samples {
        let start = ContinuousClock.now
        let step = try await agent.next(
            task: sample.task, history: sample.history, screen: sample.screen, screenshot: nil,
            registry: ActionRegistry([])
        )
        latencies.append(seconds(ContinuousClock.now - start))
        let predicted = label(step)
        let mark: String
        switch predicted {
        case sample.expected: (correct, mark) = (correct + 1, "✓")
        case "fallback": (delegated, mark) = (delegated + 1, "→")
        case "finished": (early, mark) = (early + 1, "■")
        default: (wrong, mark) = (wrong + 1, "✗")
        }
        let moment = "\(sample.task) [step \(sample.history.count + 1)]"
        print(String(format: "%@ %5.2fs  %-60@ %@ (expected %@)", mark, latencies.last ?? 0,
                     moment as NSString, predicted, sample.expected))
    }
    print("\nright          ", pct(correct, samples.count))
    print("to System Two  ", pct(delegated, samples.count))
    print("stopped early  ", pct(early, samples.count))
    print("wrong step     ", pct(wrong, samples.count))
    print(String(format: "latency         p50 %.3f  p95 %.3f", percentile(latencies, 0.5), percentile(latencies, 0.95)))
}
