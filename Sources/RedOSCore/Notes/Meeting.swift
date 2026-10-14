import Foundation

/// One finished sentence of a call.
public struct MeetingLine: Codable, Sendable, Equatable {
    public enum Speaker: String, Codable, Sendable {
        /// The microphone.
        case user
        /// The call audio.
        case others
    }

    public let speaker: Speaker
    public let text: String
    public let date: Date

    public init(speaker: Speaker, text: String, date: Date = .now) {
        self.speaker = speaker
        self.text = text
        self.date = date
    }
}

/// A call's minutes and transcript; the audio is never kept.
public struct Meeting: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public var title: String
    public let start: Date
    public let end: Date
    /// Markdown.
    public var minutes: String
    public let transcript: [MeetingLine]

    public init(id: UUID = UUID(), title: String, start: Date, end: Date, minutes: String, transcript: [MeetingLine]) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.minutes = minutes
        self.transcript = transcript
    }

    /// Minutes plus the transcript, for copying or exporting.
    public var markdown: String {
        let time = Date.FormatStyle(date: .omitted, time: .shortened)
        let lines = transcript.map { line in
            "- \(line.date.formatted(time)) **\(line.speaker.name)**: \(line.text)"
        }
        return minutes + "\n\n## " + String(localized: "Transcript") + "\n\n" + lines.joined(separator: "\n") + "\n"
    }
}

extension MeetingLine.Speaker {
    public var name: String {
        switch self {
        case .user: String(localized: "Me")
        case .others: String(localized: "Others")
        }
    }
}

/// Saved calls, one JSON file each in Application Support/RedOS/Notes, readable only by the user.
public actor MeetingStore {
    public let directory: URL

    public init(directory: URL = URL.applicationSupportDirectory.appending(path: "RedOS/Notes")) {
        self.directory = directory
    }

    /// Newest first.
    public func all() -> [Meeting] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder.meetings.decode(Meeting.self, from: Data(contentsOf: $0)) }
            .sorted { $0.start > $1.start }
    }

    public func save(_ meeting: Meeting) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = file(for: meeting.id)
        try JSONEncoder.meetings.encode(meeting).write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public func delete(_ id: UUID) throws {
        try FileManager.default.removeItem(at: file(for: id))
    }

    private func file(for id: UUID) -> URL {
        directory.appending(path: "\(id.uuidString).json")
    }
}

private extension JSONEncoder {
    static var meetings: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var meetings: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
