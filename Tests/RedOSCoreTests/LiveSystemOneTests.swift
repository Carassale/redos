import Foundation
import RedOSActions
import Testing
@testable import RedOSCore

/// Runs against a real Ollama: `make test-live`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["REDOS_LIVE_MODEL"] != nil), .serialized)
struct LiveSystemOneTests {
    private static let ollama = OllamaClient(model: ProcessInfo.processInfo.environment["REDOS_LIVE_MODEL"] ?? "")
    private let registry = ActionRegistry(SystemActions.all)
    private let router = SystemOneRouter(
        registry: ActionRegistry(SystemActions.all),
        systemOne: OllamaSystemOne(client: ollama),
        extractor: ArgumentExtractor(client: ollama),
        warmUp: [ollama]
    )

    @Test(arguments: [
        ("bring up my terminal please", "app.open"),
        ("fammi vedere il browser di Apple", "app.open"),
        ("chiudi Spotify per favore", "app.quit"),
        ("vai in fondo alla pagina", "scroll"),
        ("scrivi buongiorno a tutti", "text.type"),
        ("apri chrom e naviga su google.com", SystemOneRouter.multiStepLabel),
        ("che tempo fa domani a Milano?", SystemOneRouter.noneLabel),
    ])
    func routes(_ input: String, _ expected: String) async throws {
        await router.prepare()
        let start = ContinuousClock.now
        let decision = try await router.route(input)
        let elapsed = ContinuousClock.now - start
        let seconds = elapsed.formatted(.units(allowed: [.seconds], fractionalPart: .show(length: 2)))
        print("[live] \(seconds) \(input) -> \(decision)")

        switch decision {
        case .action(let request, _): #expect(request.actionID == expected)
        case .noAction: #expect(expected == SystemOneRouter.noneLabel)
        case .multiStep: #expect(expected == SystemOneRouter.multiStepLabel)
        case .uncertain(let actionID, _): Issue.record("Uncertain: \(actionID)")
        }
    }

    @Test(arguments: ["apri chrom e naviga su google.com", "open Safari and go to github.com"])
    func plans(_ input: String) async throws {
        try await LiveSystemTwo.expectPlan(input, client: Self.ollama, registry: registry)
    }

    @Test func answersQuestions() async throws {
        try await LiveSystemTwo.expectAnswer("che tempo fa domani a Milano?", client: Self.ollama, registry: registry)
    }
}

/// System Two through Copilot CLI: `make test-live-copilot`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["REDOS_COPILOT_PATH"] != nil), .serialized)
struct LiveCopilotTests {
    private let registry = ActionRegistry(SystemActions.all)
    private let client = CopilotCLIClient(
        executable: URL(filePath: ProcessInfo.processInfo.environment["REDOS_COPILOT_PATH"] ?? ""),
        model: ProcessInfo.processInfo.environment["REDOS_COPILOT_MODEL"]
    )

    @Test func plans() async throws {
        try await LiveSystemTwo.expectPlan("apri chrom e naviga su google.com", client: client, registry: registry)
    }

    @Test func answersQuestions() async throws {
        try await LiveSystemTwo.expectAnswer("quanto fa 17 per 23?", client: client, registry: registry)
    }
}

enum LiveSystemTwo {
    static func expectPlan(_ input: String, client: any ChatCompleting, registry: ActionRegistry) async throws {
        let result = try await timed(input) { try await ModelPlanner(client: client).plan(input, registry: registry) }
        #expect(result.steps.allSatisfy { (try? registry.validate($0)) != nil })
        #expect(result.steps.contains { $0.actionID == "url.open" })
    }

    static func expectAnswer(_ input: String, client: any ChatCompleting, registry: ActionRegistry) async throws {
        let result = try await timed(input) { try await ModelPlanner(client: client).plan(input, registry: registry) }
        #expect(result.steps.isEmpty)
        #expect(result.answer?.isEmpty == false)
    }

    private static func timed(_ input: String, _ work: () async throws -> PlanResult) async throws -> PlanResult {
        let start = ContinuousClock.now
        let result = try await work()
        let elapsed = ContinuousClock.now - start
        let seconds = elapsed.formatted(.units(allowed: [.seconds], fractionalPart: .show(length: 2)))
        print("[live] \(seconds) system two \(input) -> \(result)")
        return result
    }
}
