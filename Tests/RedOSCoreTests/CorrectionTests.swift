import Foundation
import Testing
@testable import RedOSCore

private struct FixedSystemOne: SystemOne {
    let choice: String
    let probability: Double

    func choose(_ question: JevChoiceQuestion, state: String) async throws -> JevChoiceAnswer {
        let others = question.options.map(\.label).filter { $0 != choice }
        var mass = [choice: probability]
        for label in others { mass[label] = (1 - probability) / Double(others.count) }
        return try JevChoiceAnswer(normalizing: mass, labels: question.options.map(\.label))
    }
}

private struct FailingSystemOne: SystemOne {
    func choose(_ question: JevChoiceQuestion, state: String) async throws -> JevChoiceAnswer {
        throw SystemOneError.unavailable("offline")
    }
}

private struct EchoPlanner: Planning {
    func plan(_ input: String, registry: ActionRegistry) async throws -> PlanResult {
        PlanResult(steps: [], answer: input)
    }
}

struct CorrectionTests {
    @Test(arguments: [
        ("Fermati!", Correction.stop),
        ("no", .stop),
        ("lascia stare", .stop),
        ("no, a Luca", .modify),
        ("anzi in Chrome", .modify),
        ("actually send it to Anna", .modify),
        ("e poi apri Slack", .add("apri Slack")),
        ("and then open Mail.", .add("open Mail")),
    ])
    func clearPhrasesNeedNoModel(_ utterance: String, _ expected: Correction) {
        #expect(CorrectionClassifier.rule(for: utterance) == expected)
    }

    @Test func otherPhrasesAskSystemOneWithFallback() async {
        let jevDown = CorrectionClassifier(
            deciders: [FailingSystemOne(), FixedSystemOne(choice: "add", probability: 0.9)]
        )
        #expect(await jevDown.classify("ricordati di aprire Slack", task: "apri Mail", done: [])
            == .add("ricordati di aprire Slack"))

        let unsure = CorrectionClassifier(deciders: [FixedSystemOne(choice: "modify", probability: 0.4)])
        #expect(await unsure.classify("mah vediamo", task: "apri Mail", done: []) == .unrelated)

        let chatter = CorrectionClassifier(deciders: [FixedSystemOne(choice: "unrelated", probability: 0.95)])
        #expect(await chatter.classify("ciao Marco, arrivo", task: "apri Mail", done: []) == .unrelated)
    }

    @Test func replanningTellsSystemTwoWhatWasStarted() async {
        let engine = CommandEngine(registry: ActionRegistry([]), planner: EchoPlanner(), audit: MemoryAuditLog())
        guard case .answer(let prompt) = await engine.replan(
            "apri Mail e scrivi a Marco", done: ["app.open name=Mail"], correction: "no, a Luca"
        ) else {
            Issue.record("Expected the planner to get the request")
            return
        }
        #expect(prompt.hasPrefix("apri Mail e scrivi a Marco"))
        #expect(prompt.contains("\"no, a Luca\""))
        #expect(prompt.contains("Already started: app.open name=Mail"))
    }
}
