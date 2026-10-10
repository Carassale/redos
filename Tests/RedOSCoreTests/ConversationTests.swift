import Foundation
import Testing
@testable import RedOSCore

private struct NoActionRouter: CommandRouting {
    func prepare() async {}
    func route(_ input: String) async throws -> RouteDecision { .noAction(confidence: 0.9) }
}

private struct EchoPlanner: Planning {
    func plan(_ input: String, registry: ActionRegistry) async throws -> PlanResult {
        PlanResult(steps: [], answer: input)
    }
}

struct ConversationTests {
    @Test func keepsTheLastTurnsAndForgetsAfterAPause() async {
        let conversation = Conversation()
        let start = Date(timeIntervalSince1970: 1_000_000)
        for index in 1...8 {
            await conversation.record("domanda \(index)", reply: "risposta \(index)", now: start)
        }
        let turns = await conversation.recent(now: start)
        #expect(turns.count == Conversation.maxTurns)
        #expect(turns.first?.request == "domanda 3")
        #expect(await conversation.recent(now: start + Conversation.timeout + 1).isEmpty)

        // A request after the pause starts a new conversation.
        await conversation.record("nuova", reply: "ok", now: start + Conversation.timeout + 1)
        #expect(await conversation.recent(now: start + Conversation.timeout + 2).map(\.request) == ["nuova"])
    }

    @Test func followUpsReachSystemTwoWithTheConversation() async {
        let conversation = Conversation()
        await conversation.record("che tempo fa domani a Milano?", reply: "Sereno, 18 gradi.")
        let engine = CommandEngine(
            registry: ActionRegistry([]), router: NoActionRouter(), planner: EchoPlanner(),
            conversation: conversation, audit: MemoryAuditLog()
        )
        guard case .answer(let prompt) = await engine.resolve("e a Roma?") else {
            Issue.record("Expected the planner to get the request")
            return
        }
        #expect(prompt.contains("User: che tempo fa domani a Milano?\nRedOS: Sereno, 18 gradi."))
        #expect(prompt.hasSuffix("Request: e a Roma?"))
    }

    @Test(arguments: ["Grazie.", "basta così", "ok, grazie", "That's all", "no grazie"])
    func recognizesClosingPhrases(_ text: String) {
        #expect(ClosingReply.matches(text))
    }

    @Test(arguments: ["grazie a Marco scrivi una mail", "apri Safari", "basta con le notifiche"])
    func leavesRequestsAlone(_ text: String) {
        #expect(!ClosingReply.matches(text))
    }
}
