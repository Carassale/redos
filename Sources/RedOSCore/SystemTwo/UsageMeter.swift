import Foundation

/// Cloud usage per day: requests and estimated tokens (~4 characters each).
public struct UsageRecord: Codable, Sendable, Equatable {
    public var requests = 0
    public var tokens = 0

    public init(requests: Int = 0, tokens: Int = 0) {
        self.requests = requests
        self.tokens = tokens
    }
}

public actor UsageStore {
    private let file: JSONFileStore<[String: UsageRecord]>

    public init(file: JSONFileStore<[String: UsageRecord]> = JSONFileStore(name: "usage.json", initial: [:])) {
        self.file = file
    }

    public func record(tokens: Int, on date: Date = .now) async throws {
        let day = Self.day(date)
        // Keep about a year of history.
        let oldest = Self.day(date.addingTimeInterval(-370 * 86400))
        try await file.update { days in
            days[day, default: UsageRecord()].requests += 1
            days[day, default: UsageRecord()].tokens += tokens
            days = days.filter { $0.key >= oldest }
        }
    }

    public func today(_ date: Date = .now) async -> UsageRecord {
        await file.load()[Self.day(date)] ?? UsageRecord()
    }

    public func month(_ date: Date = .now) async -> UsageRecord {
        let prefix = String(Self.day(date).prefix(7))
        return await file.load().filter { $0.key.hasPrefix(prefix) }.values.reduce(into: UsageRecord()) {
            $0.requests += $1.requests
            $0.tokens += $1.tokens
        }
    }

    private static func day(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

/// Counts cloud calls and switches to the local fallback once the daily request limit is reached.
public struct MeteredClient: ChatCompleting {
    private let inner: any ChatCompleting
    private let fallback: any ChatCompleting
    private let store: UsageStore
    /// 0 means no limit.
    private let dailyLimit: Int

    public init(inner: any ChatCompleting, fallback: any ChatCompleting, store: UsageStore, dailyLimit: Int) {
        self.inner = inner
        self.fallback = fallback
        self.store = store
        self.dailyLimit = dailyLimit
    }

    public func chat(
        _ messages: [ChatMessage], format: JSONValue?, maxTokens: Int?, topLogprobs: Int?
    ) async throws -> ChatResponse {
        if dailyLimit > 0, await store.today().requests >= dailyLimit {
            return try await fallback.chat(messages, format: format, maxTokens: maxTokens, topLogprobs: topLogprobs)
        }
        let response = try await inner.chat(messages, format: format, maxTokens: maxTokens, topLogprobs: topLogprobs)
        let characters = messages.reduce(response.message.content.count) { $0 + $1.content.count }
        try? await store.record(tokens: characters / 4)
        return response
    }

    public func preload() async {
        await inner.preload()
    }
}
