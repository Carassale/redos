import Foundation
import RedOSCore

/// Request-kind accuracy of `JevIntentRouter` on samples labeled with `kind` (eval/intents.jsonl).
func evaluateKinds(_ samples: [Sample], router: JevIntentRouter, jev: JevHTTPSystemOne) async {
    let labeled = samples.filter { $0.kind != nil }
    print("Kind eval · \(jev.model) · \(labeled.count) samples")
    _ = try? await jev.decide(state: "User request: warm up", questions: router.questions)
    var correct = 0, actionsCorrect = 0, actionSamples = 0
    var latencies: [Double] = []
    var confusions: [String: Int] = [:]
    for sample in labeled {
        let start = ContinuousClock.now
        let answers = try? await jev.decide(state: "User request: \(sample.input)", questions: router.questions)
        let elapsed = seconds(ContinuousClock.now - start)
        latencies.append(elapsed)
        let kind = answers?["kind"]?.choice ?? "error"
        let isCorrect = kind == sample.kind
        correct += isCorrect ? 1 : 0
        if !isCorrect { confusions["\(sample.kind ?? "?") → \(kind)", default: 0] += 1 }
        var detail = String(format: "%@ %.2f", kind, answers?["kind"]?.probability ?? 0)
        if sample.kind == "action" {
            actionSamples += 1
            let action = answers?["action"]?.choice ?? "-"
            actionsCorrect += action == sample.action ? 1 : 0
            detail += " · \(action)"
        }
        print(String(format: "%@ %5.2fs  %-56@ → %@", isCorrect ? "✓" : "✗", elapsed, sample.input as NSString, detail))
    }
    print("\nkind accuracy  ", pct(correct, labeled.count))
    print("action accuracy", pct(actionsCorrect, actionSamples))
    print(String(format: "latency         p50 %.3f  p95 %.3f", percentile(latencies, 0.5), percentile(latencies, 0.95)))
    for (pair, count) in confusions.sorted(by: { $0.value > $1.value }) {
        print("  \(pair): \(count)")
    }
}
