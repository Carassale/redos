import Foundation

/// A problem report or a request for the developer, opened as a pre-filled GitHub issue: the user reviews it
/// and sends it from the browser, so nothing leaves the Mac without them.
public struct Feedback: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case problem
        case request
    }

    public static let repository = "https://github.com/Carassale/redos"
    /// GitHub refuses very long URLs: long details are cut.
    static let maxDetails = 1500

    public var kind: Kind
    /// The user's own words.
    public var text: String
    /// The command that went wrong and what RedOS replied.
    public var command: String?
    public var reply: String?

    public init(kind: Kind, text: String = "", command: String? = nil, reply: String? = nil) {
        self.kind = kind
        self.text = text
        self.command = command
        self.reply = reply
    }

    /// `setup` describes the configuration (version, models); never API keys.
    public func url(setup: String) -> URL? {
        var components = URLComponents(string: "\(Self.repository)/issues/new")
        components?.queryItems = [
            URLQueryItem(name: "title", value: title),
            URLQueryItem(name: "body", value: body(setup: setup)),
            URLQueryItem(name: "labels", value: kind == .problem ? "bug" : "enhancement"),
        ]
        return components?.url
    }

    var title: String {
        let subject = [text, command ?? ""].first { !$0.isEmpty } ?? ""
        let short = subject.count > 70 ? subject.prefix(70) + "…" : subject
        return (kind == .problem ? "Problem: " : "Request: ") + short
    }

    func body(setup: String) -> String {
        var sections: [String] = []
        switch kind {
        case .problem:
            sections.append("**What happened**\n\(text.isEmpty ? "<!-- Describe the problem -->" : text)")
            if let command, !command.isEmpty { sections.append("**Command**\n> \(command)") }
            if let reply, !reply.isEmpty {
                let cut = reply.count > Self.maxDetails ? reply.prefix(Self.maxDetails) + "…" : reply
                sections.append("**RedOS replied**\n```\n\(cut)\n```")
            }
            sections.append("**What I expected**\n<!-- -->")
        case .request:
            sections.append("**Request**\n\(text.isEmpty ? "<!-- What should RedOS do? -->" : text)")
            sections.append("**Why it would help**\n<!-- -->")
        }
        return (sections + ["---\n\(setup)"]).joined(separator: "\n\n")
    }
}
