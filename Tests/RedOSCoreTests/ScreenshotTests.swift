import CoreGraphics
import Foundation
import Testing
@testable import RedOSCore

private let shot = Screenshot(
    jpeg: Data([0xFF, 0xD8, 0xFF]), width: 640, height: 400, frame: CGRect(x: 100, y: 50, width: 1280, height: 800)
)

private struct SparseScreen: ScreenObserving {
    @MainActor func observe() throws -> String { "App: Game\n[1] window \"Board\"" }
    @MainActor func screenshot() async -> Screenshot? { shot }
}

private struct ClickingAgent: Acting {
    func next(
        task: String, history: [String], screen: String, screenshot: Screenshot?, registry: ActionRegistry
    ) async throws -> AgentStep {
        guard history.isEmpty else { return .done("Fatto.") }
        return screenshot == nil ? .done("cieco") : .act(ActionRequest("mouse.click", ["x": "320", "y": "200"]))
    }
}

private struct ClickReply: ChatCompleting {
    func chat(
        _ messages: [ChatMessage], format: JSONValue?, maxTokens: Int?, topLogprobs: Int?
    ) async throws -> ChatResponse {
        ChatResponse(message: .init(content: #"{"action":"mouse.click","arguments":{"x":88,"y":140}}"#), logprobs: nil)
    }

    func preload() async {}
}

private final class RecordingChat: ChatCompleting, @unchecked Sendable {
    private(set) var messages: [ChatMessage] = []

    func chat(
        _ messages: [ChatMessage], format: JSONValue?, maxTokens: Int?, topLogprobs: Int?
    ) async throws -> ChatResponse {
        self.messages = messages
        return ChatResponse(message: .init(content: #"{"done":"ok"}"#), logprobs: nil)
    }

    func preload() async {}
}

@MainActor
struct ScreenshotTests {
    let recorder = RunRecorder()

    @Test func pixelsMapToScreenPoints() {
        #expect(shot.screenPoint(x: 320, y: 200) == CGPoint(x: 740, y: 450))
        #expect(shot.screenPoint(x: 0, y: 0) == CGPoint(x: 100, y: 50))
        #expect(shot.screenPoint(x: 640, y: 10) == nil)
        #expect(shot.screenPoint(x: -1, y: 10) == nil)
    }

    @Test func clicksByPositionNeedAScreenshot() {
        let click = ActionRequest("mouse.click", ["x": "320", "y": "200"])
        #expect(CommandEngine.onScreen(click, nil) == nil)
        #expect(CommandEngine.onScreen(click, shot) == ActionRequest("mouse.click", ["x": "740", "y": "450"]))
        #expect(CommandEngine.onScreen(ActionRequest("mouse.click", ["x": "900", "y": "1"]), shot) == nil)
        let press = ActionRequest("ui.press", ["target": "#2"])
        #expect(CommandEngine.onScreen(press, nil) == press)
    }

    @Test func screenshotsOnlyWhenTheListingIsThin() {
        let rich = (1...20).map { "[\($0)] button \"B\($0)\"" }.joined(separator: "\n")
        #expect(!CommandEngine.needsScreenshot(rich, history: []))
        #expect(CommandEngine.needsScreenshot(rich, history: ["ui.press target=#3 -> failed: not found"]))
        #expect(CommandEngine.needsScreenshot("App: Game\n[1] window \"Board\"", history: []))
    }

    @Test func agentClicksWhatItSees() async throws {
        let engine = CommandEngine(
            registry: ActionRegistry([
                FakeAction(
                    id: "mouse.click", risk: .moderate,
                    parameters: [ActionParameter("x", .integer), ActionParameter("y", .integer)], recorder: recorder
                ),
            ]),
            agent: ClickingAgent(), observer: SparseScreen(), audit: MemoryAuditLog()
        )
        #expect(try await engine.runAgent("premi il pulsante verde").get() == "Fatto.")
        #expect(recorder.runs == [["x": "740", "y": "450"]])
    }

    @Test func modelAgentSendsTheImage() async throws {
        let chat = RecordingChat()
        _ = try await ModelAgent(client: chat)
            .next(task: "x", history: [], screen: "[1] window", screenshot: shot, registry: ActionRegistry([]))
        let user = try #require(chat.messages.last)
        #expect(user.images == [shot.jpeg])
        #expect(user.content.contains("640x400 pixels"))
    }

    @Test func clickCoordinatesComeOnlyFromAScreenshot() async throws {
        let registry = ActionRegistry([
            FakeAction(
                id: "mouse.click", risk: .moderate,
                parameters: [ActionParameter("x", .integer), ActionParameter("y", .integer)], recorder: recorder
            ),
        ])
        let agent = ModelAgent(client: ClickReply())
        let task = "premi Generali"
        #expect(try await agent.next(task: task, history: [], screen: "", screenshot: shot, registry: registry)
            == .act(ActionRequest("mouse.click", ["x": "88", "y": "140"])))
        #expect(try await agent.next(task: task, history: [], screen: "", screenshot: nil, registry: registry)
            == .act(ActionRequest("mouse.click")))
    }

    @Test func providersEncodeImages() throws {
        let message = ChatMessage.user("guarda", images: [Data([1, 2, 3])])
        #expect("\(message.jsonValue)".contains("data:image/jpeg;base64,AQID"))
        #expect("\(message.anthropicJSON)".contains("AQID"))
        let ollama = try #require(String(data: try JSONEncoder().encode(message), encoding: .utf8))
        #expect(ollama.contains(#""images":["AQID"]"#))
        #expect(ChatMessage.user("solo testo").images == nil)
    }
}
