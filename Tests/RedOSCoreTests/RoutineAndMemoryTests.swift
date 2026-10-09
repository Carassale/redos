import Foundation
import Testing
@testable import RedOSCore

private struct EchoPlanner: Planning {
    func plan(_ input: String, registry: ActionRegistry) async throws -> PlanResult {
        PlanResult(steps: [], answer: input)
    }
}

private struct SelectionScreen: ScreenObserving {
    @MainActor func observe() throws -> String { "" }
    @MainActor func selectedText() -> String? { "Ciao mondo" }
}

private struct EchoChat: ChatCompleting {
    func chat(
        _ messages: [ChatMessage], format: JSONValue?, maxTokens: Int?, topLogprobs: Int?
    ) async throws -> ChatResponse {
        ChatResponse(message: .init(content: messages.last?.content ?? ""), logprobs: nil)
    }

    func preload() async {}
}

private struct FailingChat: ChatCompleting {
    func chat(
        _ messages: [ChatMessage], format: JSONValue?, maxTokens: Int?, topLogprobs: Int?
    ) async throws -> ChatResponse {
        throw ProviderError.missingAPIKey("test")
    }

    func preload() async {}
}

@MainActor
struct RoutineAndMemoryTests {
    let recorder = RunRecorder()
    let audit = MemoryAuditLog()
    let directory = FileManager.default.temporaryDirectory.appending(path: "redos-tests-\(UUID().uuidString)")

    private var routines: RoutineStore {
        RoutineStore(file: JSONFileStore(name: "routines.json", initial: [], directory: directory))
    }

    private func engine(routines: RoutineStore? = nil, memory: MemoryStore? = nil) -> CommandEngine {
        CommandEngine(
            registry: ActionRegistry([
                FakeAction(id: "app.open", parameters: [ActionParameter("name")], recorder: recorder),
                FakeAction(
                    id: "text.type", risk: .moderate, parameters: [ActionParameter("text")], recorder: recorder
                ),
            ]),
            planner: EchoPlanner(),
            observer: SelectionScreen(),
            routines: routines,
            memory: memory,
            writer: EchoChat(),
            audit: audit
        )
    }

    @Test(arguments: [
        ("crea la routine buongiorno: apri Mail e Calendario",
         MetaCommand.createRoutine(name: "buongiorno", body: "apri Mail e Calendario")),
        ("create routine \"focus\" that opens Xcode", .createRoutine(name: "focus", body: "opens Xcode")),
        ("avvia la routine buongiorno", .runRoutine("buongiorno")),
        ("run routine focus when I open Xcode", .runRoutineOnLaunch("focus", app: "Xcode")),
        ("programma la routine buongiorno alle 9:30 nei giorni feriali",
         .scheduleRoutine("buongiorno", Schedule(hour: 9, minute: 30, weekdaysOnly: true))),
        ("schedule routine focus at 2 pm", .scheduleRoutine("focus", Schedule(hour: 14, minute: 0))),
        ("elimina la routine buongiorno", .deleteRoutine("buongiorno")),
        ("quali routine ho?", .listRoutines),
        ("ricordati che il mio editor è Visual Studio Code", .remember("il mio editor è Visual Studio Code")),
        ("forget my editor", .forget("my editor")),
        ("cosa ricordi?", .recall),
    ])
    func parsesMetaCommands(_ input: String, _ expected: MetaCommand) {
        #expect(MetaCommand.parse(input) == expected)
    }

    @Test(arguments: ["ricordami di chiamare la mamma", "apri Safari", "routine", "crea una nota"])
    func leavesOtherCommandsAlone(_ input: String) {
        #expect(MetaCommand.parse(input) == nil)
    }

    @Test func routinesAreSavedAndRunWithoutModels() async throws {
        let store = routines
        let engine = engine(routines: store)
        guard case .answer = await engine.resolve("crea la routine mattina: apri Mail e scrivi ciao") else {
            Issue.record("Expected a confirmation")
            return
        }
        let steps = [ActionRequest("app.open", ["name": "Mail"]), ActionRequest("text.type", ["text": "ciao"])]
        #expect(await store.all().map(\.steps) == [steps])

        let expected = ResolvedPlan(input: "mattina", steps: steps, route: .routine)
        #expect(await engine.resolve("avvia la routine Mattina") == .plan(expected, needsConfirmation: false))
        // Nobody asked for a triggered run: steps above `safe` are confirmed.
        let triggered = await engine.resolveRoutine(named: "mattina", triggered: true)
        #expect(triggered == .plan(expected, needsConfirmation: true))

        _ = await engine.resolve("programma la routine mattina alle 8")
        #expect(await store.all().first?.schedule == Schedule(hour: 8, minute: 0))
        _ = await engine.resolve("elimina la routine mattina")
        #expect(await store.all().isEmpty)
    }

    @Test func schedulesMatchTimeAndWeekdays() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Rome"))
        let start = DateComponents(year: 2026, month: 10, day: 9, hour: 9, minute: 30)
        let friday = try #require(calendar.date(from: start))
        let saturday = friday.addingTimeInterval(86400)
        let schedule = Schedule(hour: 9, minute: 30, weekdaysOnly: true)
        #expect(schedule.matches(friday, calendar: calendar))
        #expect(!schedule.matches(saturday, calendar: calendar))
        #expect(Schedule(hour: 9, minute: 30).matches(saturday, calendar: calendar))
        #expect(!schedule.matches(friday.addingTimeInterval(60), calendar: calendar))
    }

    @Test func rememberedFactsReachSystemTwo() async throws {
        let memory = MemoryStore(file: JSONFileStore(name: "memory.json", initial: [], directory: directory))
        let engine = engine(memory: memory)
        _ = await engine.resolve("ricorda che il mio editor è Visual Studio Code")
        #expect(await memory.facts() == ["il mio editor è Visual Studio Code"])

        guard case .answer(let prompt) = await engine.resolve("apri il mio editor") else {
            Issue.record("Expected the planner to get the request")
            return
        }
        #expect(prompt.contains("- il mio editor è Visual Studio Code"))
        #expect(prompt.hasSuffix("Request: apri il mio editor"))

        _ = await engine.resolve("dimentica il mio editor")
        #expect(await memory.facts().isEmpty)
    }

    @Test func selectedTextGoesToTheWriterAsData() async {
        guard case .answer(let message) = await engine().resolve("traduci in inglese il testo selezionato") else {
            Issue.record("Expected an answer")
            return
        }
        #expect(message.contains("<<<\nCiao mondo\n>>>"))
    }

    @Test func meteredClientFallsBackPastTheDailyLimit() async throws {
        let usage = UsageStore(file: JSONFileStore(name: "usage.json", initial: [:], directory: directory))
        let client = MeteredClient(inner: EchoChat(), fallback: FailingChat(), store: usage, dailyLimit: 2)
        for _ in 0..<2 {
            _ = try await client.chat([.user("12345678")], format: nil, maxTokens: nil, topLogprobs: nil)
        }
        // 8 characters in + 8 echoed back = 4 tokens per call.
        #expect(await usage.today() == UsageRecord(requests: 2, tokens: 8))
        await #expect(throws: ProviderError.self) {
            try await client.chat([.user("x")], format: nil, maxTokens: nil, topLogprobs: nil)
        }
    }
}
