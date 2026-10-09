import Foundation

/// A JSON document in Application Support, readable only by the current user.
public actor JSONFileStore<Value: Codable & Sendable> {
    public let url: URL
    private let initial: Value
    private var cache: Value?

    public init(
        name: String, initial: Value, directory: URL = URL.applicationSupportDirectory.appending(path: "RedOS")
    ) {
        url = directory.appending(path: name)
        self.initial = initial
    }

    public func load() -> Value {
        if let cache { return cache }
        let stored = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Value.self, from: $0) }
        cache = stored ?? initial
        return cache ?? initial
    }

    public func save(_ value: Value) throws {
        cache = value
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public func update(_ change: @Sendable (inout Value) -> Void) throws {
        var value = load()
        change(&value)
        try save(value)
    }
}
