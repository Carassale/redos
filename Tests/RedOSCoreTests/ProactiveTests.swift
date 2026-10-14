import Foundation
import Testing
@testable import RedOSCore

private struct FixedJev: JevDeciding {
    let choice: String
    let probability: Double

    func decide(state: String, questions: [String: JevQuestion]) async throws -> [String: JevAnswer] {
        ["delivery": JevAnswer(choice: choice, probabilities: [choice: probability])]
    }
}

private struct EchoChat: ChatCompleting {
    func chat(
        _ messages: [ChatMessage], format: JSONValue?, maxTokens: Int?, topLogprobs: Int?
    ) async throws -> ChatResponse {
        ChatResponse(message: .init(content: messages.last?.content ?? ""), logprobs: nil)
    }

    func preload() async {}
}

struct ProactiveTests {
    private let free = UserContext(now: .now, frontmost: "Xcode", inCall: false, idleSeconds: 3)
    private let inCall = UserContext(now: .now, frontmost: "zoom.us", inCall: true, idleSeconds: 3)

    @Test func rulesWithoutJev() async {
        let policy = InterruptionPolicy(jev: nil)
        #expect(await policy.decide(.meetingSoon(title: "Standup", minutes: 5, link: nil), context: free) == .interrupt)
        #expect(await policy.decide(.batteryLow(percent: 18), context: free) == .notify)
        #expect(await policy.decide(.batteryLow(percent: 8), context: free) == .interrupt)
        #expect(await policy.decide(.callAppOpened("Zoom"), context: inCall) == .skip)
    }

    @Test func jevDecidesButNeverTalksOverACall() async {
        let quiet = InterruptionPolicy(jev: FixedJev(choice: "notify", probability: 0.9))
        #expect(await quiet.decide(.meetingSoon(title: "Standup", minutes: 3, link: nil), context: free) == .notify)

        let unsure = InterruptionPolicy(jev: FixedJev(choice: "skip", probability: 0.4))
        #expect(await unsure.decide(.batteryLow(percent: 5), context: free) == .interrupt)

        let loud = InterruptionPolicy(jev: FixedJev(choice: "interrupt", probability: 0.99))
        #expect(await loud.decide(.batteryLow(percent: 5), context: inCall) == .notify)
    }

    @Test func findsCallLinksInEvents() {
        #expect(MeetingLink.find(in: [nil, "Sala 3", "Join: https://us02web.zoom.us/j/123?pwd=x"])?.host()
            == "us02web.zoom.us")
        #expect(MeetingLink.find(in: ["https://meet.google.com/abc-defg-hij"])?.host() == "meet.google.com")
        #expect(MeetingLink.find(in: ["https://example.com/agenda"]) == nil)
    }

    @Test(arguments: ["fammi il briefing", "com'è la mia giornata?", "briefing", "what's my day like?"])
    func parsesBriefing(_ input: String) {
        #expect(MetaCommand.parse(input) == .briefing)
    }

    @Test func briefingSendsTheFactsToSystemTwo() async throws {
        let engine = CommandEngine(
            registry: ActionRegistry([]), writer: EchoChat(), persona: "Be brief.", audit: MemoryAuditLog()
        )
        let text = try #require(await engine.briefing(["Appointment at 09:30: Standup"], language: "Italian"))
        #expect(text.contains("How to talk to the user: Be brief."))
        #expect(text.contains("Language: Italian"))
        #expect(text.contains("- Appointment at 09:30: Standup"))
    }
}
