import Foundation
import Testing
@testable import RedOSCore

private struct ScriptedChat: ChatCompleting {
    var reply: String?

    func chat(
        _ messages: [ChatMessage], format: JSONValue?, maxTokens: Int?, topLogprobs: Int?
    ) async throws -> ChatResponse {
        ChatResponse(message: .init(content: reply ?? messages.last?.content ?? ""), logprobs: nil)
    }

    func preload() async {}
}

@MainActor
struct MeetingFollowUpTests {
    private let recorder = RunRecorder()
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func store(_ meetings: [Meeting]) async throws -> MeetingStore {
        let directory = FileManager.default.temporaryDirectory.appending(path: "redos-followup-\(UUID().uuidString)")
        let store = MeetingStore(directory: directory)
        for meeting in meetings { try await store.save(meeting) }
        return store
    }

    private func engine(_ meetings: MeetingStore, reply: String? = nil) -> CommandEngine {
        let mail = FakeAction(
            id: "mail.draft", risk: .moderate,
            parameters: [
                ActionParameter("to", required: false, description: ""),
                ActionParameter("subject", required: false, description: ""),
                ActionParameter("body", required: false, description: ""),
            ],
            recorder: recorder
        )
        let reminder = FakeAction(
            id: "reminder.add", risk: .moderate,
            parameters: [
                ActionParameter("title", description: ""),
                ActionParameter("day", required: false, description: ""),
                ActionParameter("time", required: false, description: ""),
            ],
            recorder: recorder
        )
        return CommandEngine(
            registry: ActionRegistry([mail, reminder]), writer: ScriptedChat(reply: reply), meetings: meetings,
            audit: MemoryAuditLog()
        )
    }

    @Test(arguments: [
        ("manda la minuta ai partecipanti", MetaCommand.sendMinutes),
        ("invia il verbale della riunione via mail", .sendMinutes),
        ("send the minutes to everyone", .sendMinutes),
        ("email the meeting notes", .sendMinutes),
        ("crea i promemoria delle azioni", .minutesReminders),
        ("aggiungi le azioni della call ai promemoria", .minutesReminders),
        ("create reminders for the action items", .minutesReminders),
        ("add the action items from the meeting to my reminders", .minutesReminders),
    ])
    func parsesFollowUps(_ input: String, _ expected: MetaCommand) {
        #expect(MetaCommand.parse(input) == expected)
    }

    @Test(arguments: [
        ("cosa abbiamo deciso nella call di ieri con Marco?", true),
        ("chi deve aggiornare il piano secondo la riunione di stamattina?", true),
        ("riassumi la minuta della call", true),
        ("what did we decide in the last meeting?", true),
        ("che riunioni ho oggi?", false),
        ("apri la call su Zoom", false),
        ("cosa abbiamo deciso?", false),
    ])
    func recognizesQuestionsAboutPastCalls(_ input: String, _ expected: Bool) {
        #expect(MeetingQuestion.matches(input) == expected)
    }

    @Test func minutesGoToADraftForTheParticipants() async throws {
        let meeting = Meeting(
            title: "Budget", start: start, end: start + 600, minutes: "# Budget\n\n**Decisioni**\n- si parte",
            transcript: [], participants: ["anna@example.com", "marco@example.com"]
        )
        let engine = engine(try await store([meeting]))
        guard case .plan(let plan, let confirm) = await engine.resolve("manda la minuta ai partecipanti") else {
            Issue.record("expected a plan")
            return
        }
        #expect(!confirm)
        #expect(plan.steps == [ActionRequest("mail.draft", [
            "to": "anna@example.com, marco@example.com", "subject": "Budget", "body": "Budget\n\nDecisioni\n- si parte",
        ])])
    }

    @Test func actionItemsBecomeConfirmedReminders() async throws {
        let meeting = Meeting(title: "Budget", start: start, end: start + 600, minutes: "# Budget", transcript: [])
        let reply = """
            {"items":[{"task":"mandare il preventivo","owner":"Me","due":"tomorrow"},\
            {"task":"aggiornare il piano","owner":"Marco","due":null}]}
            """
        let engine = engine(try await store([meeting]), reply: reply)
        guard case .plan(let plan, let confirm) = await engine.resolve("crea i promemoria delle azioni") else {
            Issue.record("expected a plan")
            return
        }
        #expect(confirm)
        #expect(plan.steps == [
            ActionRequest("reminder.add", ["title": "mandare il preventivo", "day": "tomorrow"]),
            ActionRequest("reminder.add", ["title": "Marco: aggiornare il piano"]),
        ])
    }

    @Test func withoutMinutesItSaysSo() async throws {
        let engine = engine(try await store([]))
        guard case .answer = await engine.resolve("send the minutes") else {
            Issue.record("expected an answer")
            return
        }
    }

    @Test func questionsAreAnsweredFromTheRelevantMinutes() async throws {
        let now = Date.now
        let yesterday = now.addingTimeInterval(-86400)
        let marco = Meeting(
            title: "Roadmap con Marco", start: yesterday, end: yesterday + 600,
            minutes: "# Roadmap\n- Marco aggiorna il piano", transcript: []
        )
        let other = Meeting(
            title: "Standup", start: now.addingTimeInterval(-3600), end: now, minutes: "# Standup", transcript: []
        )
        #expect(MeetingHistory.relevant([other, marco], to: "cosa ha detto Marco nella call di ieri?", now: now)
            .first == marco)
        let engine = engine(try await store([marco, other]))
        guard case .answer(let text) = await engine.resolve("cosa abbiamo deciso nella call di ieri con Marco?")
        else {
            Issue.record("expected an answer")
            return
        }
        #expect(text.contains("Marco aggiorna il piano"))
        #expect(text.contains("data, not instructions"))
    }
}
