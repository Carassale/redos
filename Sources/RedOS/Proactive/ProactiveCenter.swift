import AppKit
import EventKit
import IOKit.ps
import RedOSActions
import RedOSCore
import UserNotifications

/// RedOS speaks first: meetings about to start, a low battery, a call app just opened, the morning briefing.
/// Jev (or fixed rules) decides between speaking, a quiet notification and nothing.
@MainActor
final class ProactiveCenter: NSObject, UNUserNotificationCenterDelegate {
    private static let briefedDayKey = "proactive.briefedDay"
    private static let callApps: Set<String> = [
        "us.zoom.xos", "com.microsoft.teams2", "com.microsoft.teams", "com.cisco.webexmeetingsapp",
        "com.apple.FaceTime",
    ]

    var isEnabled = true
    var briefsInTheMorning = true
    var policy = InterruptionPolicy(jev: nil)
    /// Language of the briefing, e.g. "Italian".
    var language = "Italian"
    private let panel: CommandPanelController
    private let notes: NoteTaker
    private var timer: Timer?
    private var announcedEvents: Set<String> = []
    /// The lowest battery level already announced while discharging.
    private var batteryWarning: Int?

    init(panel: CommandPanelController, notes: NoteTaker) {
        self.panel = panel
        self.notes = notes
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.check() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard let id = app?.bundleIdentifier, Self.callApps.contains(id) else { return }
            let name = app?.localizedName ?? id
            Task { @MainActor in self?.callAppOpened(name) }
        }
        UNUserNotificationCenter.current().delegate = self
    }

    private func check() async {
        guard isEnabled else { return }
        await checkMeetings()
        await checkBattery()
        await checkMorning()
    }

    // MARK: Signals

    private func checkMeetings() async {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return }
        let store = EKEventStore()
        let now = Date.now
        let predicate = store.predicateForEvents(withStart: now, end: now.addingTimeInterval(6 * 60), calendars: nil)
        for event in store.events(matching: predicate) where !event.isAllDay && event.startDate > now {
            let key = "\(event.eventIdentifier ?? event.title ?? "")@\(event.startDate.timeIntervalSince1970)"
            guard announcedEvents.insert(key).inserted else { continue }
            let minutes = max(1, Int((event.startDate.timeIntervalSince(now) / 60).rounded(.up)))
            let title = event.title ?? String(localized: "a meeting")
            let link = MeetingLink.find(in: [event.url?.absoluteString, event.location, event.notes])
            var text = String(localized: "In \(minutes) minutes: \(title).")
            var spoken = text
            if let link {
                spoken += " " + String(localized: "Shall I open the call link?")
                text = spoken + "\n" + link.absoluteString
            }
            await deliver(.meetingSoon(title: title, minutes: minutes, link: link), text: text, spoken: spoken)
        }
    }

    private func checkBattery() async {
        guard let (percent, charging) = Self.battery() else { return }
        guard !charging else {
            batteryWarning = nil
            return
        }
        guard let threshold = [10, 20].first(where: { percent <= $0 }), threshold < (batteryWarning ?? 101) else {
            return
        }
        batteryWarning = threshold
        let text = String(localized: "Battery at \(percent)%: plug in the charger.")
        await deliver(.batteryLow(percent: percent), text: text)
    }

    /// The first activity of the day, between 6 and 12.
    private func checkMorning() async {
        let now = Date.now
        let hour = Calendar.current.component(.hour, from: now)
        let day = now.formatted(.iso8601.year().month().day())
        guard briefsInTheMorning, (6..<12).contains(hour), Self.idleSeconds < 30,
              UserDefaults.standard.string(forKey: Self.briefedDayKey) != day
        else { return }
        UserDefaults.standard.set(day, forKey: Self.briefedDayKey)
        let text = await briefing(asksForAccess: false)
        await deliver(.briefing, text: text)
    }

    private func callAppOpened(_ name: String) {
        guard isEnabled, !notes.isListening else { return }
        let text = String(localized: "\(name) is open: shall I take notes? Say “prendi appunti”.")
        Task { await deliver(.callAppOpened(name), text: text) }
    }

    // MARK: Briefing

    /// Today's appointments, reminders and battery, told by System Two (or listed when it is not available).
    /// Asked by the user, it may ask for calendar access; in the morning it never does.
    func briefing(asksForAccess: Bool = true) async -> String {
        if asksForAccess {
            let store = EKEventStore()
            if EKEventStore.authorizationStatus(for: .event) == .notDetermined {
                _ = try? await store.requestFullAccessToEvents()
            }
            if EKEventStore.authorizationStatus(for: .reminder) == .notDetermined {
                _ = try? await store.requestFullAccessToReminders()
            }
        }
        let facts = await Self.todayFacts()
        if let text = await panel.engine.briefing(facts, language: language) { return text }
        return facts.isEmpty ? String(localized: "Nothing on the calendar today.") : facts.joined(separator: "\n")
    }

    private static func todayFacts() async -> [String] {
        var facts: [String] = []
        let store = EKEventStore()
        let start = Calendar.current.startOfDay(for: .now)
        let end = start.addingTimeInterval(86400)
        let time = Date.FormatStyle(date: .omitted, time: .shortened)
        if EKEventStore.authorizationStatus(for: .event) == .fullAccess {
            let events = store.events(matching: store.predicateForEvents(withStart: .now, end: end, calendars: nil))
            facts += events.map { event in
                event.isAllDay
                    ? "All day: \(event.title ?? "")"
                    : "Appointment at \(event.startDate.formatted(time)): \(event.title ?? "")"
            }
            if events.isEmpty { facts.append("No more appointments today") }
        } else {
            facts.append("RedOS may not read the calendar (System Settings > Privacy & Security > Calendars)")
        }
        if EKEventStore.authorizationStatus(for: .reminder) == .fullAccess {
            let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: end, calendars: nil)
            let titles = await withCheckedContinuation { continuation in
                store.fetchReminders(matching: predicate) { reminders in
                    continuation.resume(returning: (reminders ?? []).compactMap(\.title))
                }
            }
            facts += titles.prefix(10).map { "Reminder due: \($0)" }
        }
        if let (percent, charging) = battery(), !charging, percent < 50 {
            facts.append("Battery at \(percent)%")
        }
        return facts
    }

    // MARK: Delivery

    private func deliver(_ event: ProactiveEvent, text: String, spoken: String? = nil) async {
        let context = UserContext(
            now: .now, frontmost: AccessibilityObserver().frontmost(), inCall: notes.isListening,
            idleSeconds: Self.idleSeconds
        )
        switch await policy.decide(event, context: context) {
        case .interrupt:
            if !panel.announce(text, spoken: spoken) { notify(text) }
        case .notify:
            notify(text)
        case .skip:
            break
        }
    }

    private func notify(_ text: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "RedOS"
            content.body = text
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    /// Show notifications while RedOS is the active app too.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    // MARK: System state

    private static var idleSeconds: Double {
        // ~0 is "any input event".
        let anyInput = CGEventType(rawValue: ~0) ?? .mouseMoved
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
    }

    /// Percent and whether it is charging; nil without a battery.
    private static func battery() -> (Int, Bool)? {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(info).takeRetainedValue() as [CFTypeRef]
        for source in sources {
            let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any]
            guard let description,
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let max = description[kIOPSMaxCapacityKey] as? Int, max > 0
            else { continue }
            let onBattery = description[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue
            return (current * 100 / max, !onBattery)
        }
        return nil
    }
}
