/// Shell-like command history: ↑ walks back from the newest entry, ↓ walks forward and finally restores the draft.
public struct CommandHistory: Sendable {
    public private(set) var entries: [String]
    public let limit: Int
    private var cursor: Int?
    private var draft = ""

    /// `entries` are ordered oldest to newest.
    public init(entries: [String] = [], limit: Int = 100) {
        self.entries = Array(entries.suffix(limit))
        self.limit = limit
    }

    public mutating func record(_ input: String) {
        resetNavigation()
        let command = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return }
        entries.removeAll { $0 == command }
        entries.append(command)
        if entries.count > limit {
            entries.removeFirst(entries.count - limit)
        }
    }

    /// Older entry, or nil when there is nothing older.
    public mutating func previous(current: String) -> String? {
        guard !entries.isEmpty else { return nil }
        let index: Int
        if let cursor {
            guard cursor > 0 else { return nil }
            index = cursor - 1
        } else {
            draft = current
            index = entries.count - 1
        }
        cursor = index
        return entries[index]
    }

    /// Newer entry, the saved draft past the newest one, or nil when not navigating.
    public mutating func next() -> String? {
        guard let cursor else { return nil }
        if cursor + 1 < entries.count {
            self.cursor = cursor + 1
            return entries[cursor + 1]
        }
        let draft = draft
        resetNavigation()
        return draft
    }

    public mutating func resetNavigation() {
        cursor = nil
        draft = ""
    }
}
