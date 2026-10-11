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

    @Test(arguments: [
        ("segnala un problema", MetaCommand.feedback(.problem, "")),
        ("segnala un errore: non apre Safari", .feedback(.problem, "non apre Safari")),
        ("report a bug the panel freezes", .feedback(.problem, "the panel freezes")),
        ("richiesta allo sviluppatore: aggiungi Spotify", .feedback(.request, "aggiungi Spotify")),
        ("invia una richiesta allo sviluppatore", .feedback(.request, "")),
        ("chiedi allo sviluppatore di supportare Teams", .feedback(.request, "supportare Teams")),
        ("feature request: dark theme", .feedback(.request, "dark theme")),
    ])
    func parsesFeedbackCommands(_ input: String, _ expected: MetaCommand) {
        #expect(MetaCommand.parse(input) == expected)
    }

    @Test func problemReportsCarryTheLastExchange() async throws {
        let conversation = Conversation()
        await conversation.record("apri Calcolatrice", reply: "App not found: Calcolatrice")
        let engine = CommandEngine(registry: ActionRegistry([]), conversation: conversation, audit: MemoryAuditLog())
        guard case .feedback(let feedback) = await engine.resolve("segnala un problema") else {
            Issue.record("Expected feedback")
            return
        }
        let expected = Feedback(kind: .problem, command: "apri Calcolatrice", reply: "App not found: Calcolatrice")
        #expect(feedback == expected)

        let url = try #require(feedback.url(setup: "RedOS 1.0 · macOS 26"))
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(url.absoluteString.hasPrefix("https://github.com/Carassale/redos/issues/new?"))
        #expect(items.first { $0.name == "title" }?.value == "Problem: apri Calcolatrice")
        #expect(items.first { $0.name == "labels" }?.value == "bug")
        let body = try #require(items.first { $0.name == "body" }?.value)
        #expect(body.contains("> apri Calcolatrice"))
        #expect(body.contains("App not found: Calcolatrice"))
        #expect(body.hasSuffix("---\nRedOS 1.0 · macOS 26"))
    }
}
