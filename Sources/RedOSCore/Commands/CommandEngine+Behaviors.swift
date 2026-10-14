import Foundation

// MARK: - Persona and standing rules

extension CommandEngine {
    /// The persona and the rules for the app in front, first in every System Two prompt.
    func standingInstructions() async -> [String] {
        var lines: [String] = []
        if let persona { lines.append("How to talk to the user: \(persona)") }
        let rules = await behaviors?.all() ?? []
        if !rules.isEmpty {
            let front = await observer?.frontmost()
            let applying = rules.filter { $0.applies(to: front) }
            if !applying.isEmpty {
                lines.append("Standing instructions from the user (follow them unless the request says otherwise):")
                lines += applying.map { "- " + ($0.app.map { "In \($0): " } ?? "") + $0.rule }
            }
        }
        return lines
    }

    func handleBehavior(_ command: MetaCommand, store: BehaviorStore) async -> String {
        do {
            switch command {
            case .addBehavior(let rule, let app):
                try await store.add(Behavior(rule: rule, app: app))
                return app.map { String(localized: "OK, in \($0) from now on: \(rule)") }
                    ?? String(localized: "OK, from now on: \(rule)")
            case .listBehaviors:
                let rules = await store.all()
                return rules.isEmpty
                    ? String(localized: "No rules yet. Say “d'ora in poi…” or “from now on…”.")
                    : rules.map { "• " + ($0.app.map { "\($0): " } ?? "") + $0.rule }.joined(separator: "\n")
            case .removeBehaviors(let topic):
                let removed = try await store.remove(matching: topic)
                return removed.isEmpty
                    ? String(localized: "No rule about “\(topic)”.")
                    : String(localized: "Removed: \(removed.map(\.rule).joined(separator: "; "))")
            default:
                return ""
            }
        } catch {
            return error.localizedDescription
        }
    }
}
