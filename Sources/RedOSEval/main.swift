import Foundation
import RedOSActions
import RedOSCore

// System One evaluation on a labeled command set: decision accuracy, safety, calibration, latency.
// Usage: swift run -c release RedOSEval [--model M] [--dataset PATH] [--jev-url URL] [--no-chain] [--out PATH]

struct Sample: Decodable {
    let lang: String
    let input: String
    let action: String
    /// Expected values; "a|b" accepts either.
    let arguments: [String: String]?
}

struct Outcome: Encodable {
    let lang: String
    let input: String
    let expected: String
    let predicted: String
    let probability: Double
    let fastPath: String?
    let arguments: [String: String]?
    let argumentsCorrect: Bool?
    /// The engine would accept the request (strict registry validation).
    let argumentsValid: Bool
    let policy: String?
    let decisionSeconds: Double
    let extractionSeconds: Double?
    let error: String?

    var decisionCorrect: Bool { predicted == expected }
    var shouldAct: Bool { ![SystemOneRouter.noneLabel, SystemOneRouter.multiStepLabel].contains(expected) }
    func acts(at threshold: Double) -> Bool { argumentsValid && probability >= threshold }
}

func option(_ name: String) -> String? {
    let arguments = CommandLine.arguments
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

func matches(_ actual: [String: String], expected: [String: String]) -> Bool {
    let fold = { (text: String) in text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
    return expected.allSatisfy { key, accepted in
        guard let value = actual[key] else { return false }
        return accepted.split(separator: "|").contains { fold(String($0)) == fold(value) }
    }
}

func seconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
}

func percentile(_ values: [Double], _ fraction: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * fraction).rounded()))]
}

func pct(_ part: Int, _ total: Int) -> String {
    total == 0 ? "-" : String(format: "%5.1f%% (%d/%d)", Double(part) * 100 / Double(total), part, total)
}

let model = option("--model") ?? "gemma4:e4b-it-qat"
let datasetPath = option("--dataset") ?? "eval/commands.jsonl"
let chains = !CommandLine.arguments.contains("--no-chain")
let ollama = OllamaClient(model: model)
let registry = ActionRegistry(SystemActions.all)
let parser = FastPathParser()
let policy = Policy()
let extractor = ArgumentExtractor(client: ollama)
let systemOne: any SystemOne = if let url = option("--jev-url").flatMap(URL.init(string:)) {
    JevHTTPSystemOne(baseURL: url)
} else {
    OllamaSystemOne(client: ollama)
}
let question = SystemOneRouter(registry: registry, systemOne: systemOne, extractor: extractor, warmUp: ollama).question

let samples = try String(contentsOfFile: datasetPath, encoding: .utf8)
    .split(separator: "\n")
    .map { try JSONDecoder().decode(Sample.self, from: Data($0.utf8)) }

print("System One eval · \(option("--jev-url") ?? model) · chain=\(chains) · \(samples.count) samples")
await ollama.preload()
_ = try? await systemOne.choose(question, state: "warm up")

var outcomes: [Outcome] = []
for sample in samples {
    let clock = ContinuousClock()
    let start = clock.now
    do {
        let answer = try await systemOne.choose(question, state: sample.input)
        let decisionSeconds = seconds(clock.now - start)
        var arguments: [String: String]?
        var extractionSeconds: Double?
        if let action = registry.action(for: answer.choice), !action.parameters.isEmpty {
            let extractionStart = clock.now
            let context = chains ? systemOne.transcript(for: question, state: sample.input, answer: answer) : []
            arguments = try await extractor.arguments(for: action, input: sample.input, context: context)
            extractionSeconds = seconds(clock.now - extractionStart)
        } else if registry.action(for: answer.choice) != nil {
            arguments = [:]
        }
        var argumentsCorrect: Bool?
        if answer.choice == sample.action, let expected = sample.arguments, let arguments {
            argumentsCorrect = matches(arguments, expected: expected)
        }
        let request = ActionRequest(answer.choice, arguments ?? [:])
        let validated = arguments == nil ? nil : try? registry.validate(request)
        outcomes.append(Outcome(
            lang: sample.lang, input: sample.input, expected: sample.action, predicted: answer.choice,
            probability: answer.probability, fastPath: parser.parse(sample.input)?.actionID,
            arguments: arguments, argumentsCorrect: argumentsCorrect, argumentsValid: validated != nil,
            policy: validated.map { "\(policy.decide(for: $0, confidence: answer.probability))" },
            decisionSeconds: decisionSeconds, extractionSeconds: extractionSeconds, error: nil
        ))
    } catch {
        outcomes.append(Outcome(
            lang: sample.lang, input: sample.input, expected: sample.action, predicted: "error", probability: 0,
            fastPath: nil, arguments: nil, argumentsCorrect: nil, argumentsValid: false, policy: nil,
            decisionSeconds: 0, extractionSeconds: nil, error: error.localizedDescription
        ))
    }
    let last = outcomes[outcomes.count - 1]
    let mark = last.decisionCorrect && last.argumentsCorrect != false ? "✓" : "✗"
    print(String(format: "%@ %4.2f %5.2fs  %-52@ → %@ %@", mark, last.probability,
                 last.decisionSeconds + (last.extractionSeconds ?? 0), last.input as NSString,
                 last.predicted, last.arguments.map { "\($0)" } ?? ""))
}

print("\n## Decision")
print("accuracy        ", pct(outcomes.filter(\.decisionCorrect).count, outcomes.count))
for lang in Set(outcomes.map(\.lang)).sorted() {
    let subset = outcomes.filter { $0.lang == lang }
    print("accuracy \(lang)     ", pct(subset.filter(\.decisionCorrect).count, subset.count))
}
let argumentChecks = outcomes.compactMap(\.argumentsCorrect)
print("arguments       ", pct(argumentChecks.filter { $0 }.count, argumentChecks.count))
let fastPathHits = outcomes.filter { $0.fastPath != nil }
print("fast path hits  ", pct(fastPathHits.filter { $0.fastPath == $0.expected }.count, fastPathHits.count),
      "correct of matched")

let brier = outcomes.map { pow($0.probability - ($0.decisionCorrect ? 1 : 0), 2) }.reduce(0, +)
    / Double(outcomes.count)
print(String(format: "brier score      %.3f (lower is better)", brier))

print("\n## Threshold sweep (act only when p ≥ t and arguments are valid)")
print("t     coverage            precision           false actions on 'none'/'multi_step'")
for threshold in [0.5, 0.6, 0.7, 0.8, 0.85, 0.9, 0.95] {
    let acted = outcomes.filter { $0.acts(at: threshold) }
    let shouldAct = outcomes.filter(\.shouldAct)
    let none = outcomes.filter { !$0.shouldAct }
    print(String(format: "%.2f  ", threshold),
          pct(acted.filter(\.decisionCorrect).count, shouldAct.count), " ",
          pct(acted.filter(\.decisionCorrect).count, acted.count), " ",
          pct(acted.filter { !$0.shouldAct }.count, none.count))
}

let threshold = Double(option("--threshold") ?? "0.5") ?? 0.5
let wrong = outcomes.filter { $0.acts(at: threshold) && !$0.decisionCorrect }
print("\n## Safety at t=\(threshold) with the default policy")
print("wrong actions auto-run         ", wrong.filter { $0.policy == "allow" }.map(\.input))
print("wrong actions needing confirm  ", wrong.filter { $0.policy == "confirm" }.map(\.input))

print("\n## Latency (s)")
let decisions = outcomes.map(\.decisionSeconds)
let extractions = outcomes.compactMap(\.extractionSeconds)
let totals = outcomes.map { $0.decisionSeconds + ($0.extractionSeconds ?? 0) }
for (name, values) in [("decision", decisions), ("extraction", extractions), ("total", totals)] {
    let p50 = percentile(values, 0.5), p95 = percentile(values, 0.95)
    print(String(format: "%-11@ p50 %.2f  p95 %.2f", name as NSString, p50, p95))
}

if let outPath = option("--out") {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let lines = try outcomes.map { String(bytes: try encoder.encode($0), encoding: .utf8) ?? "" }
    try FileManager.default.createDirectory(
        at: URL(filePath: outPath).deletingLastPathComponent(), withIntermediateDirectories: true
    )
    try (lines.joined(separator: "\n") + "\n").write(toFile: outPath, atomically: true, encoding: .utf8)
    print("\nresults → \(outPath)")
}
