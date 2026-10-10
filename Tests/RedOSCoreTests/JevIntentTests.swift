import Foundation
import Testing
@testable import RedOSCore

private struct FakeJev: JevDeciding {
    let kind: String
    var kindProbability = 0.95
    var action = "none"
    var actionProbability = 0.95

    func decide(state: String, questions: [String: JevQuestion]) async throws -> [String: JevAnswer] {
        [
            "kind": JevAnswer(choice: kind, probabilities: [kind: kindProbability], confidence: 0.9),
            "action": JevAnswer(choice: action, probabilities: [action: actionProbability], confidence: 0.9),
        ]
    }
}

private struct FailingRouter: CommandRouting {
    func prepare() async {}
    func route(_ input: String) async throws -> RouteDecision { throw SystemOneError.unavailable("offline") }
}

private struct FixedRouter: CommandRouting {
    let decision: RouteDecision
    func prepare() async {}
    func route(_ input: String) async throws -> RouteDecision { decision }
}

private struct ReplyChat: ChatCompleting {
    let content: String

    func chat(
        _ messages: [ChatMessage], format: JSONValue?, maxTokens: Int?, topLogprobs: Int?
    ) async throws -> ChatResponse {
        ChatResponse(message: .init(content: content), logprobs: nil)
    }

    func preload() async {}
}

@MainActor
struct JevIntentTests {
    private let registry = ActionRegistry([
        FakeAction(id: "app.open", parameters: [ActionParameter("name")], recorder: RunRecorder()),
        FakeAction(id: "ui.read", recorder: RunRecorder()),
    ])

    private func router(_ jev: FakeJev, extracting: String? = nil) -> JevIntentRouter {
        let extractor = extracting.map { ArgumentExtractor(client: ReplyChat(content: $0)) }
        return JevIntentRouter(registry: registry, jev: jev, extractor: extractor, threshold: 0.8)
    }

    @Test func asksKindAndActionInOneRequest() throws {
        let questions = router(FakeJev(kind: "action")).questions
        #expect(Set(questions.keys) == ["kind", "action"])
        let body = JevHTTPSystemOne.body(state: "User request: x", questions: questions, model: "openjev-latest")
        #expect(body["questions"]?["kind"]?["type"] == "choice")
        #expect(body["questions"]?["action"]?["criteria"]?["app.open"] != nil)
        #expect(body["questions"]?["action"]?["criteria"]?["none"] != nil)
        #expect(body["model"] == "openjev-latest")
    }

    @Test func mapsKindsToDecisions() async throws {
        #expect(try await router(FakeJev(kind: "screen_question")).route("x") == .screenQuestion(confidence: 0.95))
        #expect(try await router(FakeJev(kind: "screen_task")).route("x") == .screenTask(confidence: 0.95))
        #expect(try await router(FakeJev(kind: "current_info")).route("x") == .research(confidence: 0.95))
        #expect(try await router(FakeJev(kind: "diagram")).route("x") == .diagram(confidence: 0.95))
        #expect(try await router(FakeJev(kind: "steps")).route("x") == .multiStep(confidence: 0.95))
        #expect(try await router(FakeJev(kind: "knowledge")).route("x") == .noAction(confidence: 0.95))
        // Unsure about the kind: System Two decides.
        let unsureKind = FakeJev(kind: "diagram", kindProbability: 0.5)
        #expect(try await router(unsureKind).route("x") == .noAction(confidence: 0.5))
    }

    @Test func extractsArgumentsOrDefersToSystemTwo() async throws {
        let open = FakeJev(kind: "action", action: "app.open")
        let routed = try await router(open, extracting: #"{"name": "Safari"}"#).route("apri Safari")
        #expect(routed == .action(ActionRequest("app.open", ["name": "Safari"]), confidence: 0.95))
        // No local model for the arguments: System Two fills them.
        #expect(try await router(open).route("apri Safari") == .uncertain(actionID: "app.open", confidence: 0.95))
        // Actions without parameters need no extraction.
        let read = FakeJev(kind: "action", action: "ui.read")
        #expect(try await router(read).route("leggi") == .action(ActionRequest("ui.read"), confidence: 0.95))
        let unsure = FakeJev(kind: "action", action: "app.open", actionProbability: 0.6)
        #expect(try await router(unsure).route("x") == .uncertain(actionID: "app.open", confidence: 0.6))
    }

    @Test func localActionsWinAndJevSortsTheRest() async throws {
        let open = RouteDecision.action(ActionRequest("app.open", ["name": "Safari"]), confidence: 0.95)
        let action = HybridRouter(local: FixedRouter(decision: open), remote: FailingRouter())
        #expect(try await action.route("apri Safari") == open)

        let question = HybridRouter(
            local: FixedRouter(decision: .noAction(confidence: 0.6)),
            remote: FixedRouter(decision: .screenQuestion(confidence: 0.98))
        )
        #expect(try await question.route("di cosa parla questa pagina?") == .screenQuestion(confidence: 0.98))

        // Jev alone thinks it is an action: System Two settles it.
        let disputed = HybridRouter(
            local: FixedRouter(decision: .noAction(confidence: 0.6)), remote: FixedRouter(decision: open)
        )
        #expect(try await disputed.route("x") == .uncertain(actionID: "app.open", confidence: 0.95))

        // Offline: the local decision stands.
        let offline = HybridRouter(local: FixedRouter(decision: .multiStep(confidence: 0.9)), remote: FailingRouter())
        #expect(try await offline.route("x") == .multiStep(confidence: 0.9))

        // "di cosa parla questa finestra?": a confident screen question beats the local ui.read.
        let read = RouteDecision.action(ActionRequest("ui.read"), confidence: 0.99)
        let screen = HybridRouter(
            local: FixedRouter(decision: read), remote: FixedRouter(decision: .screenQuestion(confidence: 0.97))
        )
        #expect(try await screen.route("x") == .screenQuestion(confidence: 0.97))
    }

    @Test func decodesNoulAndScoreAnswers() throws {
        let data = Data(#"""
            {"model":"openjev-latest","answers":{
              "urgent":{"noul":0.97},
              "tone":{"score":1.2,"legend":["calm","annoyed","furious"],"probabilities":[0.1,0.6,0.3],"confidence":0.4},
              "team":{"choice":"billing","probabilities":{"billing":0.8,"tech":0.2},"confidence":0.5}}}
            """#.utf8)
        let answers = try JevHTTPSystemOne.answers(from: data)
        #expect(answers["urgent"]?.probability == 0.97)
        #expect(answers["tone"]?.score == 1.2)
        #expect(answers["team"]?.choice == "billing")
        #expect(answers["team"]?.probability == 0.8)
    }
}
