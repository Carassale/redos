import Foundation

/// A named sequence of validated actions, optionally run on a schedule or when an app opens.
public struct Routine: Codable, Sendable, Equatable, Identifiable {
    public var name: String
    public var steps: [ActionRequest]
    public var schedule: Schedule?
    /// Runs when this app is launched.
    public var launchApp: String?

    public var id: String { name.lowercased() }

    public init(name: String, steps: [ActionRequest], schedule: Schedule? = nil, launchApp: String? = nil) {
        self.name = name
        self.steps = steps
        self.schedule = schedule
        self.launchApp = launchApp
    }
}

/// Daily at a time, optionally Monday to Friday only.
public struct Schedule: Codable, Sendable, Equatable {
    public var hour: Int
    public var minute: Int
    public var weekdaysOnly: Bool

    public init(hour: Int, minute: Int, weekdaysOnly: Bool = false) {
        self.hour = hour
        self.minute = minute
        self.weekdaysOnly = weekdaysOnly
    }

    public func matches(_ date: Date, calendar: Calendar = .current) -> Bool {
        let parts = calendar.dateComponents([.hour, .minute, .weekday], from: date)
        guard parts.hour == hour, parts.minute == minute else { return false }
        // Gregorian weekday: 1 = Sunday, 7 = Saturday.
        return !weekdaysOnly || (2...6).contains(parts.weekday ?? 1)
    }

    public var time: String {
        String(format: "%02d:%02d", hour, minute)
    }
}

/// Routines in `routines.json`, looked up by name (case and accent insensitive).
public actor RoutineStore {
    private let file: JSONFileStore<[Routine]>

    public init(file: JSONFileStore<[Routine]> = JSONFileStore(name: "routines.json", initial: [])) {
        self.file = file
    }

    public func all() async -> [Routine] {
        await file.load()
    }

    public func routine(named name: String) async -> Routine? {
        let routines = await file.load()
        return NameMatcher.bestMatch(for: name, in: routines.map(\.name)).map { routines[$0] }
    }

    /// Replaces a routine with the same name, keeping its triggers when the new one has none.
    public func save(_ routine: Routine) async throws {
        try await file.update { routines in
            var routine = routine
            if let index = routines.firstIndex(where: { $0.id == routine.id }) {
                routine.schedule = routine.schedule ?? routines[index].schedule
                routine.launchApp = routine.launchApp ?? routines[index].launchApp
                routines[index] = routine
            } else {
                routines.append(routine)
            }
        }
    }

    public func remove(named name: String) async throws -> Routine? {
        guard let routine = await routine(named: name) else { return nil }
        try await file.update { $0.removeAll { $0.id == routine.id } }
        return routine
    }

    public func update(named name: String, _ change: @Sendable (inout Routine) -> Void) async throws -> Routine? {
        guard var routine = await routine(named: name) else { return nil }
        change(&routine)
        let updated = routine
        try await file.update { routines in
            if let index = routines.firstIndex(where: { $0.id == updated.id }) { routines[index] = updated }
        }
        return updated
    }
}

/// Facts the user asked to remember, given to System Two and the agent as context.
public actor MemoryStore {
    public static let maxFacts = 50
    public static let maxLength = 300
    private let file: JSONFileStore<[String]>

    public init(file: JSONFileStore<[String]> = JSONFileStore(name: "memory.json", initial: [])) {
        self.file = file
    }

    public func facts() async -> [String] {
        await file.load()
    }

    public func remember(_ fact: String) async throws {
        let fact = String(fact.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            .prefix(Self.maxLength))
        guard !fact.isEmpty else { return }
        try await file.update { facts in
            facts.removeAll { $0.caseInsensitiveCompare(fact) == .orderedSame }
            facts.append(fact)
            facts = Array(facts.suffix(Self.maxFacts))
        }
    }

    /// Removes the facts mentioning `topic`; returns them.
    public func forget(_ topic: String) async throws -> [String] {
        let facts = await file.load()
        let query = topic.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        let removed = facts.filter {
            $0.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        guard !removed.isEmpty else { return [] }
        try await file.update { $0.removeAll(where: removed.contains) }
        return removed
    }

    public func remove(_ fact: String) async throws {
        try await file.update { $0.removeAll { $0 == fact } }
    }
}
