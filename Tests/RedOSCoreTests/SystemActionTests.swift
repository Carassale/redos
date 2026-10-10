import Foundation
import RedOSCore
import Testing
@testable import RedOSActions

struct SystemActionTests {
    @Test func shortcutsAreNotShellCommands() {
        let parser = FastPathParser()
        #expect(parser.parse("esegui il comando rapido Casa") == ActionRequest("shortcut.run", ["name": "Casa"]))
        #expect(parser.parse("esegui il comando ls") == ActionRequest("shell.run", ["command": "ls"]))
    }

    @Test func findsAppsByLocalizedName() throws {
        #expect(try InstalledApps.url(named: "Calcolatrice").lastPathComponent == "Calculator.app")
        #expect(try InstalledApps.url(named: "Calculator").lastPathComponent == "Calculator.app")
        #expect(try InstalledApps.url(named: "Note").lastPathComponent == "Notes.app")
    }

    @Test func remindersGetADueDate() throws {
        var calendar = Calendar.current
        calendar.timeZone = .current
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 10, hour: 15)))
        let tomorrow = try #require(ReminderAction.dueDate(day: "tomorrow", time: "18:30", now: now))
        let expected = DateComponents(day: 11, hour: 18, minute: 30)
        #expect(calendar.dateComponents([.day, .hour, .minute], from: tomorrow) == expected)
        let today = try #require(ReminderAction.dueDate(day: nil, time: "9", now: now))
        #expect(calendar.component(.day, from: today) == 10)
        #expect(ReminderAction.dueDate(day: nil, time: nil, now: now) == nil)
    }

    @Test func newActionsAreRegisteredWithRisk() {
        let actions = Dictionary(uniqueKeysWithValues: SystemActions.all.map { ($0.id, $0.risk) })
        #expect(actions["volume.set"] == .safe)
        #expect(actions["window.arrange"] == .safe)
        #expect(actions["shortcut.run"] == .moderate)
        #expect(actions["mail.draft"] == .moderate)
        #expect(actions["shell.run"] == .dangerous)
        #expect(AppleScript.quoted(#"say "hi" \ bye"#) == #""say \"hi\" \\ bye""#)
    }
}
