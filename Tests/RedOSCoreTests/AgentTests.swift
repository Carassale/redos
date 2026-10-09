import Foundation
import Testing
@testable import RedOSCore

private struct ScriptedAgent: Acting {
    let steps: [AgentStep]

    func next(task: String, history: [String], screen: String, registry: ActionRegistry) async throws -> AgentStep {
        history.count < steps.count ? steps[history.count] : .done("fine")
    }
}

private struct FixedScreen: ScreenObserving {
    @MainActor func observe() throws -> String { "App: Test\n[1] button \"OK\"" }
}

private struct AgentPlanner: Planning {
    func plan(_ input: String, registry: ActionRegistry) async throws -> PlanResult {
        PlanResult(steps: [], needsScreen: true)
    }
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
struct AgentTests {
    let recorder = RunRecorder()
    let audit = MemoryAuditLog()

    private func engine(_ steps: [AgentStep]) -> CommandEngine {
        CommandEngine(
            registry: ActionRegistry([
                FakeAction(
                    id: "ui.press", risk: .moderate, parameters: [ActionParameter("target")], recorder: recorder
                ),
                FakeAction(
                    id: "shell.run", risk: .dangerous, parameters: [ActionParameter("command")], recorder: recorder
                ),
            ]),
            router: MultiStepRouter(),
            planner: AgentPlanner(),
            agent: ScriptedAgent(steps: steps),
            observer: FixedScreen(),
            audit: audit
        )
    }

    @Test func screenTasksAreHandedToTheAgent() async {
        #expect(await engine([]).resolve("apri il primo menu") == .agent("apri il primo menu"))
    }

    @Test func agentRunsStepsAndRefusesDangerousActions() async throws {
        let press = ActionRequest("ui.press", ["target": "#1"])
        let engine = engine([.act(ActionRequest("shell.run", ["command": "rm -rf ~"])), .act(press), .done("Fatto.")])
        let summary = try await engine.runAgent("premi OK").get()

        #expect(summary == "Fatto.")
        #expect(recorder.runs == [["target": "#1"]])
        #expect(await audit.entries.map(\.route) == [.agent])
    }

    @Test func agentFinishesWhenRedoingTheLastStep() async throws {
        let press = ActionRequest("ui.press", ["target": "#1"])
        let summary = try await engine(Array(repeating: .act(press), count: 6)).runAgent("premi OK").get()
        #expect(summary == nil)
        #expect(recorder.runs.count == 1)
    }

    @Test func agentStopsWhenRepeatingAFailingStep() async {
        let step = ActionRequest("ui.press", ["target": "#9"])
        let engine = CommandEngine(
            registry: ActionRegistry([
                FakeAction(
                    id: "ui.press", parameters: [ActionParameter("target")], error: .failed("not found"),
                    recorder: recorder
                )
            ]),
            agent: ScriptedAgent(steps: Array(repeating: .act(step), count: 6)),
            observer: FixedScreen(),
            audit: audit
        )
        let result = await engine.runAgent("premi OK")
        #expect(throws: ActionError.self) { try result.get() }
        #expect(recorder.runs.count == 3)
    }

    @Test func cancelledAgentStops() async {
        let press = ActionRequest("ui.press", ["target": "#1"])
        let engine = engine([.act(press)])
        let task = Task { await engine.runAgent("premi OK") }
        task.cancel()
        await #expect(throws: ActionError.cancelled) { try await task.value.get() }
    }

    @Test func modelAgentParsesActionsAndDone() async throws {
        let registry = ActionRegistry([
            FakeAction(id: "ui.press", parameters: [ActionParameter("target")], recorder: recorder)
        ])
        let reply = ##"{"action":"ui.press","arguments":{"target":"#3"}}"##
        let act = try await ModelAgent(client: FixedChat(content: reply))
            .next(task: "x", history: [], screen: "", registry: registry)
        #expect(act == .act(ActionRequest("ui.press", ["target": "#3"])))
        let done = try await ModelAgent(client: FixedChat(content: #"{"done":"Fatto."}"#))
            .next(task: "x", history: [], screen: "", registry: registry)
        #expect(done == .done("Fatto."))
    }

    @Test func plannerFlagsScreenTasks() async throws {
        let result = try await ModelPlanner(client: FixedChat(content: #"{"steps":[],"agent":true}"#))
            .plan("apri il primo menu", registry: ActionRegistry([]))
        #expect(result.needsScreen)
    }

    @Test(arguments: [
        ("il pulsante Salva", "Salva"), ("the Login button", "Login"), ("sul link \"Chi siamo\"", "Chi siamo"),
    ])
    func cleansTargets(_ text: String, _ expected: String) {
        #expect(UITarget.clean(text) == expected)
    }

    @Test(arguments: ["il primo risultato", "the blue button", "300, 200", "il pulsante", "invio"])
    func rejectsDescribedTargets(_ text: String) {
        #expect(UITarget.clean(text) == nil)
    }
}
