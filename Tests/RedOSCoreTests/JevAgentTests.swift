import Foundation
import Testing
@testable import RedOSCore

private struct FixedJev: JevDeciding {
    let answers: [String: JevAnswer]

    func decide(state: String, questions: [String: JevQuestion]) async throws -> [String: JevAnswer] {
        answers
    }
}

private struct FailingJev: JevDeciding {
    func decide(state: String, questions: [String: JevQuestion]) async throws -> [String: JevAnswer] {
        throw SystemOneError.unavailable("offline")
    }
}

/// Stands in for System Two: always types "fallback".
private struct FallbackAgent: Acting {
    func next(task: String, history: [String], screen: String, registry: ActionRegistry) async throws -> AgentStep {
        .act(ActionRequest("ui.fill", ["target": "#2", "text": "fallback"]))
    }
}

private let screen = """
    App: Finder, window "Downloads"
    [1] menu "File"
    [2] field "Search"
    [3] button "Share" = "off"
    Text: Downloads
    """

private func answer(_ choice: String, _ probability: Double) -> JevAnswer {
    JevAnswer(choice: choice, probabilities: [choice: probability])
}

struct JevAgentTests {
    private let registry = ActionRegistry([])
    private let fallback = ActionRequest("ui.fill", ["target": "#2", "text": "fallback"])

    @Test func readsTheNumberedElements() {
        #expect(JevAgent.elements(in: screen) == [
            .init(id: 1, description: "menu \"File\""), .init(id: 2, description: "field \"Search\""),
            .init(id: 3, description: "button \"Share\" = \"off\""),
        ])
        guard case .choice(_, let options) = JevAgent.firstStepQuestions(JevAgent.elements(in: screen))["element"]
        else {
            Issue.record("Expected an element choice")
            return
        }
        #expect(options.map(\.label) == ["#1", "#2", "#3"])
    }

    @Test func confidentClicksAndScrollsNeedNoSystemTwo() async throws {
        let press = JevAgent(jev: FixedJev(answers: ["next": answer("press", 0.9), "element": answer("#3", 0.8)]),
                             fallback: FallbackAgent())
        #expect(try await press.next(task: "share", history: [], screen: screen, registry: registry)
            == .act(ActionRequest("ui.press", ["target": "#3"])))

        let scroll = JevAgent(jev: FixedJev(answers: ["next": answer("scroll_down", 0.95)]), fallback: FallbackAgent())
        #expect(try await scroll.next(task: "x", history: [], screen: screen, registry: registry)
            == .act(ActionRequest("scroll", ["direction": "down"])))

        let done = JevAgent(jev: FixedJev(answers: ["status": answer("finished", 0.6)]), fallback: FallbackAgent())
        let history = ["ui.press target=#1 -> ok"]
        #expect(try await done.next(task: "x", history: history, screen: screen, registry: registry) == .done(nil))
    }

    @Test func laterStepsTypingDoubtsAndOutagesGoToSystemTwo() async throws {
        let history = ["ui.press target=#1 -> ok"]
        let going = JevAgent(
            jev: FixedJev(answers: ["status": answer("continue", 0.9), "next": answer("press", 0.99),
                                    "element": answer("#3", 0.99)]),
            fallback: FallbackAgent()
        )
        #expect(try await going.next(task: "x", history: history, screen: screen, registry: registry) == .act(fallback))

        let cases: [any JevDeciding] = [
            FixedJev(answers: ["next": answer("type", 0.95), "element": answer("#2", 0.9)]),
            FixedJev(answers: ["next": answer("press", 0.5), "element": answer("#1", 0.9)]),
            FixedJev(answers: ["next": answer("press", 0.9), "element": answer("#1", 0.3)]),
            FixedJev(answers: ["next": answer("other", 0.95)]),
            FailingJev(),
        ]
        for jev in cases {
            let agent = JevAgent(jev: jev, fallback: FallbackAgent())
            #expect(try await agent.next(task: "x", history: [], screen: screen, registry: registry) == .act(fallback))
        }
    }
}
