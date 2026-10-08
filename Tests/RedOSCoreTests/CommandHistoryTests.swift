import Testing
@testable import RedOSCore

struct CommandHistoryTests {
    @Test func navigatesBackAndForthRestoringTheDraft() {
        var history = CommandHistory(entries: ["apri Safari", "scrolla giù"])

        #expect(history.previous(current: "draft") == "scrolla giù")
        #expect(history.previous(current: "scrolla giù") == "apri Safari")
        #expect(history.previous(current: "apri Safari") == nil)
        #expect(history.next() == "scrolla giù")
        #expect(history.next() == "draft")
        #expect(history.next() == nil)
    }

    @Test func recordMovesDuplicatesToNewestAndResetsNavigation() {
        var history = CommandHistory(entries: ["a", "b", "c"])
        _ = history.previous(current: "")

        history.record("  a ")
        history.record("")

        #expect(history.entries == ["b", "c", "a"])
        #expect(history.previous(current: "") == "a")
    }

    @Test func keepsOnlyTheNewestEntries() {
        var history = CommandHistory(entries: ["1", "2", "3"], limit: 3)
        history.record("4")
        #expect(history.entries == ["2", "3", "4"])
        #expect(CommandHistory(entries: ["1", "2", "3"], limit: 2).entries == ["2", "3"])
    }

    @Test func emptyHistoryDoesNothing() {
        var history = CommandHistory()
        #expect(history.previous(current: "x") == nil)
        #expect(history.next() == nil)
    }
}
