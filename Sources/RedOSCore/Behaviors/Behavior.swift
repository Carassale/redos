import Foundation

/// A standing instruction said by voice: "d'ora in poi rispondimi in breve", "quando uso Slack, scrivi in
/// inglese" (only while that app is in front).
public struct Behavior: Codable, Sendable, Equatable, Identifiable {
    public var id: String { (app.map { "\($0): " } ?? "") + rule }
    public let rule: String
    public let app: String?

    public init(rule: String, app: String? = nil) {
        self.rule = rule
        self.app = app
    }

    /// The rule applies when the frontmost app ("Slack — #general") is its app, or always without one.
    func applies(to frontmost: String?) -> Bool {
        guard let app else { return true }
        guard let frontmost else { return false }
        let name = frontmost.components(separatedBy: " — ").first ?? frontmost
        return name.localizedCaseInsensitiveContains(app) || app.localizedCaseInsensitiveContains(name)
    }
}

/// Rules given to System Two with every request, after the persona.
public actor BehaviorStore {
    public static let maxRules = 30
    public static let maxLength = 300
    private let file: JSONFileStore<[Behavior]>

    public init(file: JSONFileStore<[Behavior]> = JSONFileStore(name: "behaviors.json", initial: [])) {
        self.file = file
    }

    public func all() async -> [Behavior] {
        await file.load()
    }

    public func add(_ behavior: Behavior) async throws {
        let rule = String(behavior.rule.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            .prefix(Self.maxLength))
        guard !rule.isEmpty else { return }
        let added = Behavior(rule: rule, app: behavior.app)
        try await file.update { rules in
            rules.removeAll { $0.rule.caseInsensitiveCompare(rule) == .orderedSame && $0.app == added.app }
            rules.append(added)
            rules = Array(rules.suffix(Self.maxRules))
        }
    }

    /// Removes the rules mentioning `topic` ("" removes all); returns them.
    public func remove(matching topic: String) async throws -> [Behavior] {
        let rules = await file.load()
        let query = topic.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        let removed = query.isEmpty ? rules : rules.filter {
            $0.id.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        guard !removed.isEmpty else { return [] }
        try await file.update { $0.removeAll(where: removed.contains) }
        return removed
    }
}

/// How RedOS talks: a preset or the user's own description.
public enum Persona: String, CaseIterable, Sendable, Identifiable {
    case neutral
    case butler
    case friendly
    case concise
    case custom

    public var id: String { rawValue }

    /// Instructions for System Two; nil for neutral (and for an empty custom text).
    public func instructions(custom: String) -> String? {
        switch self {
        case .neutral:
            nil
        case .butler:
            "Speak like a discreet, impeccably polite butler in the spirit of Jarvis: formal, precise, with a touch"
                + " of dry wit; address the user formally (in Italian with \"Lei\")."
        case .friendly:
            "Be warm and informal, like a helpful friend; address the user informally (in Italian with \"tu\")."
        case .concise:
            "Be extremely brief: one short sentence when possible, no pleasantries."
        case .custom:
            custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : custom
        }
    }
}
