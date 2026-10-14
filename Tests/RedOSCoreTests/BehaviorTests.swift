import Foundation
import Testing
@testable import RedOSCore

private struct EchoPlanner: Planning {
    func plan(_ input: String, registry: ActionRegistry) async throws -> PlanResult {
        PlanResult(steps: [], answer: input)
    }
}

private struct NoActionRouter: CommandRouting {
    func prepare() async {}
    func route(_ input: String) async throws -> RouteDecision { .noAction(confidence: 0.9) }
}

private struct SlackInFront: ScreenObserving {
    @MainActor func observe() throws -> String { "" }
    @MainActor func frontmost() -> String? { "Slack — #general" }
}

struct BehaviorTests {
    @Test(arguments: [
        ("d'ora in poi rispondimi in modo breve", MetaCommand.addBehavior(rule: "rispondimi in modo breve", app: nil)),
        ("Da ora in poi, dammi del lei.", .addBehavior(rule: "dammi del lei", app: nil)),
        ("from now on answer in English", .addBehavior(rule: "answer in English", app: nil)),
        ("quando uso Slack, scrivi in inglese", .addBehavior(rule: "scrivi in inglese", app: "Slack")),
        ("d'ora in poi quando sono in Xcode usa Swift", .addBehavior(rule: "usa Swift", app: "Xcode")),
        ("when I'm in Mail, sign as Gabriele", .addBehavior(rule: "sign as Gabriele", app: "Mail")),
        ("quali regole hai?", .listBehaviors),
        ("dimentica la regola sulle risposte brevi", .removeBehaviors("risposte brevi")),
        ("dimentica tutte le regole", .removeBehaviors("")),
        ("forget the rule about English", .removeBehaviors("English")),
    ])
    func parsesRuleCommands(_ input: String, _ expected: MetaCommand) {
        #expect(MetaCommand.parse(input) == expected)
    }

    @Test func memoryCommandsStillWork() {
        #expect(MetaCommand.parse("dimentica il mio editor") == .forget("il mio editor"))
    }

    @Test func rulesAndPersonaReachSystemTwoForTheAppInFront() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "redos-rules-\(UUID().uuidString)")
        let store = BehaviorStore(file: JSONFileStore(name: "behaviors.json", initial: [], directory: directory))
        let engine = CommandEngine(
            registry: ActionRegistry([]), router: NoActionRouter(), planner: EchoPlanner(), observer: SlackInFront(),
            behaviors: store, persona: Persona.concise.instructions(custom: ""), audit: MemoryAuditLog()
        )
        _ = await engine.resolve("d'ora in poi rispondimi in modo breve")
        _ = await engine.resolve("quando uso Slack, scrivi in inglese")
        _ = await engine.resolve("quando uso Xcode, usa Swift")
        #expect(await store.all().count == 3)

        guard case .answer(let prompt) = await engine.resolve("come si dice grazie?") else {
            Issue.record("Expected the planner to get the request")
            return
        }
        #expect(prompt.contains("How to talk to the user: Be extremely brief"))
        #expect(prompt.contains("- rispondimi in modo breve"))
        #expect(prompt.contains("- In Slack: scrivi in inglese"))
        #expect(!prompt.contains("Xcode"))

        _ = await engine.resolve("dimentica la regola su Slack")
        #expect(await store.all().map(\.rule) == ["rispondimi in modo breve", "usa Swift"])
    }

    @Test func personasHaveInstructionsExceptNeutral() {
        #expect(Persona.neutral.instructions(custom: "x") == nil)
        #expect(Persona.custom.instructions(custom: "  ") == nil)
        #expect(Persona.custom.instructions(custom: "Parla come un pirata") == "Parla come un pirata")
        #expect(Persona.butler.instructions(custom: "")?.contains("Jarvis") == true)
    }
}
