import Testing
@testable import RedOSCore

private struct StaticPlanner: Planning {
    let steps: [ActionRequest]

    func plan(_ input: String, registry: ActionRegistry) async throws -> [ActionRequest] { steps }
}

private struct MultiStepRouter: CommandRouting {
    func prepare() async {}
    func route(_ input: String) async throws -> RouteDecision { .multiStep(confidence: 0.9) }
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

    private func engine(_ steps: [ActionRequest]) -> CommandEngine {
        CommandEngine(
            registry: ActionRegistry(actions),
            router: MultiStepRouter(),
            planner: StaticPlanner(steps: steps),
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

    @Test func plannerParsesStepsAndDropsInventedNumbers() async throws {
        let chat = FixedChat(content: #"""
            {"steps": [{"action": "url.open", "arguments": {"url": "google.com"}},
                       {"action": "mouse.move", "arguments": {"x": 960, "y": 540}}]}
            """#)
        let steps = try await OllamaPlanner(client: chat)
            .plan("vai su google.com e al centro", registry: ActionRegistry(actions))

        #expect(steps == [ActionRequest("url.open", ["url": "google.com"]), ActionRequest("mouse.move")])
    }

    @Test func plannerRejectsOverlongPlans() async {
        let step = #"{"action": "app.open", "arguments": {"name": "Safari"}}"#
        let chat = FixedChat(content: #"{"steps": [\#(Array(repeating: step, count: 7).joined(separator: ","))]}"#)
        await #expect(throws: PlanError.tooManySteps(7)) {
            try await OllamaPlanner(client: chat).plan("tante cose", registry: ActionRegistry(actions))
        }
    }
}
