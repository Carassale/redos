import Foundation
import Testing
@testable import RedOSCore

private struct FakeChat: ChatCompleting {
    var content = ""
    var alternatives: [(String, Double)] = []

    func chat(
        _ messages: [ChatMessage], format: JSONValue?, maxTokens: Int?, topLogprobs: Int?
    ) async throws -> ChatResponse {
        let top = alternatives.map { ChatResponse.TokenLogprob.Alternative(token: $0.0, logprob: log($0.1)) }
        let logprob = ChatResponse.TokenLogprob(token: top.first?.token ?? "", logprob: 0, topLogprobs: top)
        return ChatResponse(message: .init(content: content), logprobs: [logprob])
    }

    func preload() async {}
}

private let question = JevChoiceQuestion(
    instructions: "Pick one.",
    options: [
        JevOption(label: "app.open", description: "Open an app"),
        JevOption(label: "scroll", description: "Scroll"),
        JevOption(label: "none", description: "None"),
    ]
)

struct SystemOneTests {
    @Test func answerNormalizesMassAndComputesConfidence() throws {
        let answer = try JevChoiceAnswer(normalizing: ["a": 3, "b": 1], labels: ["a", "b", "c"])
        #expect(answer.choice == "a")
        #expect(answer.probability == 0.75)
        #expect(answer.probabilities["c"] == 0)
        #expect(answer.confidence > 0 && answer.confidence < 1)

        let certain = try JevChoiceAnswer(normalizing: ["b": 0.2], labels: ["a", "b"])
        #expect(certain.choice == "b")
        #expect(certain.confidence == 1)

        #expect(throws: SystemOneError.noDecision) { try JevChoiceAnswer(normalizing: [:], labels: ["a"]) }
    }

    @Test func ollamaSystemOneMapsLetterTokensToLabels() async throws {
        let chat = FakeChat(alternatives: [("A", 0.6), (" B", 0.2), ("The", 0.15), ("C", 0.05)])
        let answer = try await OllamaSystemOne(client: chat).choose(question, state: "open safari")

        #expect(answer.choice == "app.open")
        #expect(abs(answer.probability - 0.6 / 0.85) < 1e-9)
        #expect(abs((answer.probabilities["scroll"] ?? 0) - 0.2 / 0.85) < 1e-9)
    }

    @Test func extractorConvertsJSONToValidatedArguments() async throws {
        let action = FakeAction(
            id: "scroll",
            parameters: [
                ActionParameter("direction", .oneOf(["up", "down"])),
                ActionParameter("amount", .integer, required: false),
            ],
            recorder: await RunRecorder()
        )
        let chat = FakeChat(content: #"{"direction": "down", "amount": 10}"#)
        let arguments = try await ArgumentExtractor(client: chat).arguments(for: action, input: "giù di 10")

        #expect(arguments == ["direction": "down", "amount": "10"])
        #expect(try ActionRegistry([action]).validate(ActionRequest("scroll", arguments)).id == "scroll")
    }

    @Test func extractorDropsNumbersTheUserDidNotSay() async throws {
        let action = FakeAction(
            id: "mouse.move",
            parameters: [ActionParameter("x", .integer), ActionParameter("y", .integer)],
            recorder: await RunRecorder()
        )
        let invented = FakeChat(content: #"{"x": 960, "y": 540}"#)
        let extractor = ArgumentExtractor(client: invented)

        #expect(try await extractor.arguments(for: action, input: "move the mouse to the center").isEmpty)
        #expect(try await extractor.arguments(for: action, input: "move to 960, 540") == ["x": "960", "y": "540"])
    }

    @Test func jevResponseIsDecoded() throws {
        let data = Data(#"""
            {"model":"localjev-0.2","answers":{"action":{"type":"choice","choice":"scroll",
            "probabilities":{"app.open":0.1,"scroll":0.9,"none":0},"confidence":0.7}},"usage":{}}
            """#.utf8)
        let answer = try JevHTTPSystemOne.answer(from: data)
        #expect(answer.choice == "scroll")
        #expect(answer.probability == 0.9)
    }

    @Test func routerReturnsNoActionOrUncertainOrAction() async throws {
        let action = FakeAction(id: "app.open", parameters: [ActionParameter("name")], recorder: await RunRecorder())
        let registry = ActionRegistry([action])
        func router(_ alternatives: [(String, Double)]) -> SystemOneRouter {
            let chat = FakeChat(content: #"{"name": "Terminal"}"#, alternatives: alternatives)
            return SystemOneRouter(
                registry: registry,
                systemOne: OllamaSystemOne(client: chat),
                extractor: ArgumentExtractor(client: chat),
                warmUp: chat,
                threshold: 0.6
            )
        }

        // Options are lettered in registry order, with "none" last: A = app.open, B = none.
        #expect(try await router([("B", 0.9), ("A", 0.1)]).route("ciao") == .noAction(confidence: 0.9))
        #expect(
            try await router([("A", 0.5), ("B", 0.5)]).route("boh")
                == .uncertain(actionID: "app.open", confidence: 0.5)
        )
        #expect(
            try await router([("A", 0.95), ("B", 0.05)]).route("bring up my terminal")
                == .action(ActionRequest("app.open", ["name": "Terminal"]), confidence: 0.95)
        )
    }
}
