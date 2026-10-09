import Foundation
import Testing
@testable import RedOSCore

private struct PageScreen: ScreenObserving {
    @MainActor func observe() throws -> String { "" }
    @MainActor func screenContent() -> ScreenContent? {
        ScreenContent(
            app: "Google Chrome", window: "Fix login (!42) · GitLab", address: "https://gitlab.example.com/mr/42",
            text: "Fix login\nAssignee\nMario Rossi\nReviewers\nAnna"
        )
    }
    @MainActor func frontmost() -> String? { "Google Chrome — Fix login (!42) · GitLab" }
}

/// Echoes the last user message, so tests can see what the model was given.
private struct EchoChat: ChatCompleting {
    func chat(
        _ messages: [ChatMessage], format: JSONValue?, maxTokens: Int?, topLogprobs: Int?
    ) async throws -> ChatResponse {
        ChatResponse(message: .init(content: messages.last?.content ?? ""), logprobs: nil)
    }

    func preload() async {}
}

private struct EchoPlanner: Planning {
    func plan(_ input: String, registry: ActionRegistry) async throws -> PlanResult {
        PlanResult(steps: [], answer: input)
    }
}

private struct AnyRouter: CommandRouting {
    func prepare() async {}
    func route(_ input: String) async throws -> RouteDecision { .noAction(confidence: 0.9) }
}

@MainActor
struct ScreenQuestionTests {
    private func engine() -> CommandEngine {
        CommandEngine(
            registry: ActionRegistry([]), router: AnyRouter(), planner: EchoPlanner(), assistant: EchoPlanner(),
            observer: PageScreen(), writer: EchoChat(), audit: MemoryAuditLog()
        )
    }

    @Test(arguments: [
        "a chi è assegnata questa MR?", "riassumi questa pagina", "cosa dice questa email?",
        "what is this page about?", "dimmi cosa c'è sullo schermo", "quanto costa questo prodotto?",
        "who wrote this article?", "dammi info sulla pagina visualizzata",
    ])
    func recognizesScreenQuestions(_ input: String) {
        #expect(ScreenQuestion.matches(input))
    }

    @Test(arguments: [
        "chiudi questa finestra", "che tempo fa questa settimana a Milano?", "apri questa pagina in Safari",
        "what's on this week at the cinema?", "chi è Fedez?", "apri Safari",
    ])
    func leavesOtherRequestsAlone(_ input: String) {
        #expect(!ScreenQuestion.matches(input))
    }

    @Test func screenQuestionsAreAnsweredFromTheScreen() async {
        guard case .answer(let message) = await engine().resolve("a chi è assegnata questa MR?") else {
            Issue.record("Expected an answer")
            return
        }
        #expect(message.contains("Window: Fix login (!42) · GitLab"))
        #expect(message.contains("Address: https://gitlab.example.com/mr/42"))
        #expect(message.contains("Assignee\nMario Rossi"))
    }

    @Test func systemTwoKnowsWhatIsOnScreen() async {
        guard case .answer(let prompt) = await engine().resolve("chiudila") else {
            Issue.record("Expected the planner to get the request")
            return
        }
        #expect(prompt.contains("On screen now: Google Chrome — Fix login (!42) · GitLab"))
        #expect(prompt.hasSuffix("Request: chiudila"))
    }

    @Test func plannerCanAskToLook() async throws {
        let chat = FixedReply(content: #"{"steps":[],"look":true}"#)
        let result = try await ModelPlanner(client: chat).plan("di cosa parla?", registry: ActionRegistry([]))
        #expect(result.look)
    }

    @Test func agentOnlyGetsElementActions() {
        let recorder = RunRecorder()
        let registry = ActionRegistry([
            FakeAction(id: "ui.press", parameters: [ActionParameter("target")], recorder: recorder),
            FakeAction(id: "text.type", parameters: [ActionParameter("text")], recorder: recorder),
            FakeAction(id: "app.quit", parameters: [ActionParameter("name")], recorder: recorder),
        ])
        let prompt = ModelAgent.systemPrompt(for: registry)
        #expect(prompt.contains("- ui.press("))
        #expect(!prompt.contains("- text.type("))
        #expect(!prompt.contains("- app.quit("))
    }
}

private struct FixedReply: ChatCompleting {
    let content: String

    func chat(
        _ messages: [ChatMessage], format: JSONValue?, maxTokens: Int?, topLogprobs: Int?
    ) async throws -> ChatResponse {
        ChatResponse(message: .init(content: content), logprobs: nil)
    }

    func preload() async {}
}
