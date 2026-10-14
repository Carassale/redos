import Foundation
import Testing
@testable import RedOSCore

private struct EchoChat: ChatCompleting {
    var reply: String?

    func chat(
        _ messages: [ChatMessage], format: JSONValue?, maxTokens: Int?, topLogprobs: Int?
    ) async throws -> ChatResponse {
        ChatResponse(message: .init(content: reply ?? messages.last?.content ?? ""), logprobs: nil)
    }

    func preload() async {}
}

struct NotesTests {
    @Test(arguments: [
        ("prendi appunti", MetaCommand.takeNotes(true)),
        ("inizia a prendere appunti della call", .takeNotes(true)),
        ("take notes of this meeting", .takeNotes(true)),
        ("smetti di prendere appunti", .takeNotes(false)),
        ("basta appunti", .takeNotes(false)),
        ("stop taking notes", .takeNotes(false)),
    ])
    func parsesNoteCommands(_ input: String, _ expected: MetaCommand) {
        #expect(MetaCommand.parse(input) == expected)
    }

    @Test(arguments: ["prendi nota che domani piove", "apri le note", "scrivi negli appunti ciao"])
    func leavesOtherNotesAlone(_ input: String) {
        #expect(MetaCommand.parse(input) == nil)
    }

    @Test func notesUpdateAfterEnoughTalk() {
        #expect(!MeetingNotes.isDue(newWords: 40, since: .seconds(30)))
        #expect(MeetingNotes.isDue(newWords: 120, since: .seconds(5)))
        #expect(MeetingNotes.isDue(newWords: 20, since: .seconds(100)))
        #expect(!MeetingNotes.isDue(newWords: 5, since: .seconds(300)))
    }

    @Test func updatesSendOnlyTheNewLinesAsData() async throws {
        let notes = MeetingNotes(client: EchoChat())
        let lines = [MeetingLine(speaker: .user, text: "partiamo lunedì"), MeetingLine(speaker: .others, text: "ok")]
        let message = try await notes.update(notes: "**Topics**\n- budget", with: lines)
        #expect(message.contains("Current notes:\n**Topics**\n- budget"))
        #expect(message.contains("Me: partiamo lunedì"))
        #expect(message.contains("Others: ok"))
    }

    @Test func minutesTakeTheTitleFromTheirHeading() async throws {
        let notes = MeetingNotes(client: EchoChat(reply: "# Avvio progetto\n\n**Sintesi**\n- si parte lunedì"))
        let lines = [MeetingLine(speaker: .user, text: "si parte lunedì")]
        let result = try await notes.minutes(of: lines, notes: "", title: nil)
        #expect(result.title == "Avvio progetto")
        let fromCalendar = try await notes.minutes(of: lines, notes: "", title: "Weekly")
        #expect(fromCalendar.title == "Weekly")
    }

    @Test func meetingsAreSavedListedAndDeleted() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "redos-notes-\(UUID().uuidString)")
        let store = MeetingStore(directory: directory)
        let start = Date(timeIntervalSince1970: 1_000_000)
        let old = Meeting(title: "Old", start: start, end: start + 60, minutes: "# Old", transcript: [])
        let new = Meeting(
            title: "New", start: start + 3600, end: start + 4000, minutes: "# New",
            transcript: [MeetingLine(speaker: .others, text: "ciao", date: start + 3610)]
        )
        try await store.save(old)
        try await store.save(new)
        #expect(await store.all().map(\.title) == ["New", "Old"])
        #expect(await store.all().first == new)
        #expect(new.markdown.contains("**Others**: ciao"))
        try await store.delete(old.id)
        #expect(await store.all().map(\.title) == ["New"])
    }
}
