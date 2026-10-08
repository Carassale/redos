import Foundation
import OSLog

public struct AuditEntry: Codable, Sendable, Equatable {
    public enum Outcome: String, Codable, Sendable {
        case unrecognized
        case invalid
        case denied
        case cancelled
        case completed
        case failed
    }

    public enum Route: String, Codable, Sendable {
        case fastPath
        case systemOne
    }

    public var date: Date
    public var input: String
    public var route: Route?
    public var confidence: Double?
    public var actionID: String?
    public var arguments: [String: String]
    public var risk: RiskLevel?
    public var outcome: Outcome
    public var error: String?
}

public protocol AuditLogging: Sendable {
    func record(_ entry: AuditEntry) async
}

/// Append-only JSON Lines log, readable only by the current user.
public actor FileAuditLog: AuditLogging {
    public static var defaultURL: URL {
        URL.applicationSupportDirectory.appending(path: "RedOS/audit.jsonl")
    }

    public let url: URL
    private let encoder = JSONEncoder()
    private let logger = Logger(subsystem: "dev.redos.RedOS", category: "audit")

    public init(url: URL = FileAuditLog.defaultURL) {
        self.url = url
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
    }

    public func record(_ entry: AuditEntry) {
        do {
            var line = try encoder.encode(entry)
            line.append(0x0A)
            let fileManager = FileManager.default
            if !fileManager.fileExists(atPath: url.path) {
                try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                fileManager.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } catch {
            // Auditing must never break command execution.
            logger.error("Audit write failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
