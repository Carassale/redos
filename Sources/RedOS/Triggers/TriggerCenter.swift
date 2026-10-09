import AppKit
import RedOSCore

/// Runs routines on their schedule and when their app is launched.
@MainActor
final class TriggerCenter {
    private let routines: RoutineStore
    private let run: (Routine) -> Void
    private var timer: Timer?
    private var launchObserver: NSObjectProtocol?
    /// Routine id -> the minute it last fired, so a schedule fires once.
    private var lastFired: [String: Date] = [:]

    init(routines: RoutineStore, run: @escaping (Routine) -> Void) {
        self.routines = routines
        self.run = run
    }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        launchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let name = app?.localizedName ?? ""
            MainActor.assumeIsolated { self?.launched(name) }
        }
    }

    private func tick() {
        let now = Date()
        let minute = Calendar.current.dateInterval(of: .minute, for: now)?.start ?? now
        Task {
            for routine in await routines.all() where routine.schedule?.matches(now) == true {
                guard lastFired[routine.id] != minute else { continue }
                lastFired[routine.id] = minute
                run(routine)
            }
        }
    }

    private func launched(_ app: String) {
        guard !app.isEmpty else { return }
        Task {
            for routine in await routines.all() {
                guard let trigger = routine.launchApp, NameMatcher.bestMatch(for: trigger, in: [app]) != nil else {
                    continue
                }
                run(routine)
            }
        }
    }
}
