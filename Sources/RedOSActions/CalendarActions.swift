import EventKit
import Foundation
import RedOSCore

struct AgendaAction: ReportingAction {
    let id = "calendar.agenda"
    let summary = "List the events in the user's calendars for today, tomorrow or this week."
    let risk = RiskLevel.safe
    let parameters = [
        ActionParameter(
            "day", .oneOf(["today", "tomorrow", "week"]), required: false,
            description: "The day the user asks about: today, tomorrow (domani) or the week"
        ),
    ]

    @MainActor
    func report(_ arguments: ActionArguments) async throws -> String {
        let store = EKEventStore()
        guard try await store.requestFullAccessToEvents() else { throw CalendarAccess.denied("Calendars") }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let (start, days) = switch arguments["day"] {
        case "tomorrow": (calendar.date(byAdding: .day, value: 1, to: today) ?? today, 1)
        case "week": (today, 7)
        default: (today, 1)
        }
        let end = calendar.date(byAdding: .day, value: days, to: start) ?? start
        let events = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
            .sorted { $0.startDate < $1.startDate }
        guard !events.isEmpty else { return String(localized: "No events.") }
        return events.map { event in
            let time = event.isAllDay
                ? String(localized: "all day")
                : event.startDate.formatted(date: days > 1 ? .abbreviated : .omitted, time: .shortened)
            let place = event.location.flatMap { $0.isEmpty ? nil : " · \($0)" } ?? ""
            return "\(time) \(event.title ?? "")\(place)"
        }.joined(separator: "\n")
    }
}

struct ReminderAction: Action {
    let id = "reminder.add"
    let summary = "Add a reminder to the Reminders app, optionally due today or tomorrow at a time."
    let risk = RiskLevel.moderate
    let parameters = [
        ActionParameter("title", description: "What to remember"),
        ActionParameter("day", .oneOf(["today", "tomorrow"]), required: false, description: "Due day, only if stated"),
        ActionParameter("time", required: false, description: "Due time as HH:MM, only if stated"),
    ]

    @MainActor
    func run(_ arguments: ActionArguments) async throws {
        let store = EKEventStore()
        guard try await store.requestFullAccessToReminders() else { throw CalendarAccess.denied("Reminders") }
        let reminder = EKReminder(eventStore: store)
        reminder.title = try arguments.string("title")
        reminder.calendar = store.defaultCalendarForNewReminders()
        if let due = Self.dueDate(day: arguments["day"], time: arguments["time"]) {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: due
            )
            reminder.addAlarm(EKAlarm(absoluteDate: due))
        }
        do {
            try store.save(reminder, commit: true)
        } catch {
            throw ActionError.failed(error.localizedDescription)
        }
    }

    static func dueDate(day: String?, time: String?, now: Date = .now) -> Date? {
        guard day != nil || time != nil else { return nil }
        let calendar = Calendar.current
        let day = day == "tomorrow" ? calendar.date(byAdding: .day, value: 1, to: now) ?? now : now
        let parts = (time ?? "9:00").split(whereSeparator: { $0 == ":" || $0 == "." }).compactMap { Int($0) }
        return calendar.date(
            bySettingHour: parts.first ?? 9, minute: parts.count > 1 ? parts[1] : 0, second: 0,
            of: calendar.startOfDay(for: day)
        )
    }
}

enum CalendarAccess {
    static func denied(_ app: String) -> ActionError {
        .failed(String(localized: "RedOS has no access to \(app) (System Settings > Privacy & Security)."))
    }
}
