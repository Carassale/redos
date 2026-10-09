import Foundation
import Testing
@testable import RedOSCore

private struct StaticPlanner: Planning {
    let result: PlanResult

    func plan(_ input: String, registry: ActionRegistry) async throws -> PlanResult { result }
}

private struct FixedRouter: CommandRouting {
    var decision = RouteDecision.multiStep(confidence: 0.9)

    func prepare() async {}
    func route(_ input: String) async throws -> RouteDecision { decision }
}

private struct FixedChat: ChatCompleting {
    let content: String

    func chat(
        _ messages: [ChatMessage], format: JSONValue?, maxTokens: Int?, topLogprobs: Int?
    ) async throws -> ChatResponse {
        ChatResponse(message: .init(content: content), logprobs: nil)
    }

    func preload() async {}
}

@MainActor
struct PlannerTests {
    let recorder = RunRecorder()
    let audit = MemoryAuditLog()

    private var actions: [any Action] {
        [
            FakeAction(id: "app.open", parameters: [ActionParameter("name")], recorder: recorder),
            FakeAction(
                id: "url.open",
                parameters: [ActionParameter("url"), ActionParameter("app", required: false)],
                recorder: recorder
            ),
            FakeAction(
                id: "mouse.move",
                parameters: [ActionParameter("x", .integer), ActionParameter("y", .integer)],
                recorder: recorder
            ),
        ]
    }

    private func engine(
        _ steps: [ActionRequest], answer: String? = nil, decision: RouteDecision = .multiStep(confidence: 0.9)
    ) -> CommandEngine {
        CommandEngine(
            registry: ActionRegistry(actions),
            router: FixedRouter(decision: decision),
            planner: StaticPlanner(result: PlanResult(steps: steps, answer: answer)),
            audit: audit
        )
    }

    @Test func multiStepRequestBecomesAPlanThatRunsInOrder() async throws {
        let steps = [
            ActionRequest("app.open", ["name": "Google Chrome"]),
            ActionRequest("url.open", ["url": "google.com", "app": "Google Chrome"]),
        ]
        let engine = engine(steps)
        let resolution = await engine.resolve("apri chrome e naviga su google.com")
        #expect(resolution == .plan(ResolvedPlan(input: "apri chrome e naviga su google.com", steps: steps)))

        guard case .plan(let plan) = resolution else { return }
        _ = try await engine.execute(plan).get()
        #expect(recorder.runs == steps.map(\.arguments))
        #expect(await audit.entries.map(\.route) == [.systemTwo, .systemTwo])
    }

    @Test func emptyOrInvalidPlansAreNotRun() async {
        #expect(await engine([]).resolve("fai il caffè") == .unrecognized)

        let invalid = ActionRequest("mouse.move", ["x": "10"])
        #expect(await engine([invalid]).resolve("muovi") == .invalid(invalid, .missingArgument("y")))
        #expect(recorder.runs.isEmpty)
    }

    @Test func questionsAndUncertainCommandsGetSystemTwoAnswers() async {
        let answer = "17 × 23 = 391"
        let question = engine([], answer: answer, decision: .noAction(confidence: 0.9))
        #expect(await question.resolve("17 per 23?") == .answer(answer))
        let uncertain = RouteDecision.uncertain(actionID: "app.open", confidence: 0.4)
        #expect(await engine([], answer: "?", decision: uncertain).resolve("boh") == .answer("?"))
        #expect(await audit.entries.map(\.outcome) == [.answered, .answered])
    }

    @Test func plannerReadsAnswersAndJSONWrappedInProse() async throws {
        let chat = FixedChat(content: """
            Here is the plan:
            ```json
            {"steps": [], "answer": "Non posso vedere il meteo."}
            ```
            """)
        let result = try await ModelPlanner(client: chat).plan("che tempo fa?", registry: ActionRegistry(actions))
        #expect(result == PlanResult(steps: [], answer: "Non posso vedere il meteo."))

        await #expect(throws: PlanError.unreadable) {
            try await ModelPlanner(client: FixedChat(content: "no json here"))
                .plan("x", registry: ActionRegistry(actions))
        }
    }

    @Test func copilotClientRunsTheCLIWithToolsDisabled() async throws {
        // /bin/echo stands in for `copilot`: the reply is the argument list it received.
        let client = CopilotCLIClient(executable: URL(filePath: "/bin/echo"), model: "claude-haiku-5.5")
        let reply = try await client.chat(
            [.system("S"), .user("U")], format: .string("json"), maxTokens: nil, topLogprobs: nil
        )

        #expect(reply.message.content.contains("--available-tools="))
        #expect(reply.message.content.contains("--disable-builtin-mcps"))
        #expect(reply.message.content.hasSuffix("--model claude-haiku-5.5"))
    }

    @Test func cliTimeoutStopsTheProcess() async {
        await #expect(throws: ProviderError.self) {
            try await CopilotCLIClient.run(URL(filePath: "/bin/sleep"), ["5"], timeout: .milliseconds(200))
        }
    }

    @Test func plannerParsesStepsAndDropsInventedNumbers() async throws {
        let chat = FixedChat(content: #"""
            {"steps": [{"action": "url.open", "arguments": {"url": "google.com"}},
                       {"action": "mouse.move", "arguments": {"x": 960, "y": 540}}]}
            """#)
        let result = try await ModelPlanner(client: chat)
            .plan("vai su google.com e al centro", registry: ActionRegistry(actions))

        #expect(result.steps == [ActionRequest("url.open", ["url": "google.com"]), ActionRequest("mouse.move")])
    }

    @Test func plannerRejectsOverlongPlans() async {
        let step = #"{"action": "app.open", "arguments": {"name": "Safari"}}"#
        let chat = FixedChat(content: #"{"steps": [\#(Array(repeating: step, count: 7).joined(separator: ","))]}"#)
        await #expect(throws: PlanError.tooManySteps(7)) {
            try await ModelPlanner(client: chat).plan("tante cose", registry: ActionRegistry(actions))
        }
    }
}
