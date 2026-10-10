import Foundation

/// Recent exchanges, so follow-ups like "e domani?" make sense; forgotten after a few quiet minutes.
public actor Conversation {
    public struct Turn: Sendable, Equatable {
        public let request: String
        public let reply: String
    }

    static let maxTurns = 6
    static let timeout: TimeInterval = 300
    private var turns: [Turn] = []
    private var lastUpdate = Date.distantPast

    public init() {}

    public func record(_ request: String, reply: String, now: Date = .now) {
        let request = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty else { return }
        turns = Array((recent(now: now) + [Turn(request: request, reply: String(reply.prefix(400)))])
            .suffix(Self.maxTurns))
        lastUpdate = now
    }

    public func recent(now: Date = .now) -> [Turn] {
        now.timeIntervalSince(lastUpdate) > Self.timeout ? [] : turns
    }

    public func clear() {
        turns = []
    }

    /// The exchanges as prompt lines, oldest first; empty when there is no recent conversation.
    func transcript(now: Date = .now) -> [String] {
        let turns = recent(now: now)
        guard !turns.isEmpty else { return [] }
        return ["Recent conversation (oldest first; use it to understand follow-ups like \"and tomorrow?\"):"]
            + turns.flatMap { ["User: \($0.request)", "RedOS: \($0.reply.replacingOccurrences(of: "\n", with: " "))"] }
    }
}
