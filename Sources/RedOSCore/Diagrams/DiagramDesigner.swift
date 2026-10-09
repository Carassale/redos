import Foundation

/// The bundled diagram-design skill (MIT, Cathryn Lavery): style guide, primitives, 44 visual types with examples.
public struct DiagramLibrary: Sendable {
    public struct VisualType: Sendable, Equatable {
        public let id: String
        public let name: String
        public let use: String
    }

    public let directory: URL
    public let types: [VisualType]

    public init?(directory: URL) {
        guard let skill = try? String(contentsOf: directory.appending(path: "SKILL.md"), encoding: .utf8) else {
            return nil
        }
        self.directory = directory
        types = Self.types(in: skill)
        guard !types.isEmpty else { return nil }
    }

    /// Rows of the skill's visual-type guide: "| If you're showing… | **Name** | [type-id.md](…) |".
    static func types(in skill: String) -> [VisualType] {
        skill.split(separator: "\n").compactMap { line in
            let row = /^\|\s*(.+?)\s*\|\s*\*\*(.+?)\*\*\s*\|\s*\[type-([a-z-]+)\.md\]/
            guard let match = line.firstMatch(of: row) else { return nil }
            return VisualType(id: String(match.3), name: String(match.2), use: String(match.1))
        }
    }

    func reference(_ name: String) -> String {
        (try? String(contentsOf: directory.appending(path: "references/\(name).md"), encoding: .utf8)) ?? ""
    }

    func example(_ type: String) -> String {
        (try? String(contentsOf: directory.appending(path: "assets/example-\(type).html"), encoding: .utf8)) ?? ""
    }
}

public struct Diagram: Sendable, Equatable {
    public let title: String
    public let type: String
    public let file: URL
}

public enum DiagramError: Error, LocalizedError, Equatable {
    case noDiagram

    public var errorDescription: String? {
        String(localized: "The model did not produce a diagram. Try a cloud provider for diagrams.")
    }
}

/// Draws a diagram as a self-contained HTML/SVG file following the diagram-design style.
public struct DiagramDesigner: Sendable {
    private let client: any ChatCompleting
    private let library: DiagramLibrary
    private let output: URL

    public init(
        client: any ChatCompleting, library: DiagramLibrary,
        output: URL = URL.applicationSupportDirectory.appending(path: "RedOS/Diagrams")
    ) {
        self.client = client
        self.library = library
        self.output = output
    }

    private struct Choice: Decodable {
        let type: String?
        let title: String?
    }

    public func draw(_ request: String) async throws -> Diagram {
        await ActivityReporter.report(.thinking)
        let choice = try await choose(request)
        let type = library.types.first { $0.id == choice.type } ?? library.types.first { $0.id == "flowchart" }!
        await ActivityReporter.report(.drawing(type.name))
        let response = try await client.chat(
            [.system(designPrompt(for: type)), .user(request)], format: nil, maxTokens: 16000, topLogprobs: nil
        )
        guard let html = Self.document(in: response.message.content) else { throw DiagramError.noDiagram }
        let title = choice.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? type.name
        return Diagram(title: title, type: type.name, file: try save(html, title: title))
    }

    private func choose(_ request: String) async throws -> Choice {
        let list = library.types.map { "- \($0.id): \($0.name) — \($0.use)" }.joined(separator: "\n")
        let prompt = """
            Pick the visual type that best fits the user's diagram request.
            \(list)
            Reply with compact JSON only: {"type":"<id>","title":"<short title in the user's language>"}
            """
        let response = try await client.chat(
            [.system(prompt), .user(request)], format: .string("json"), maxTokens: 120, topLogprobs: nil
        )
        let json = JSONText.firstObject(in: response.message.content) ?? "{}"
        return (try? JSONDecoder().decode(Choice.self, from: Data(json.utf8))) ?? Choice(type: nil, title: nil)
    }

    func designPrompt(for type: DiagramLibrary.VisualType) -> String {
        """
        You draw one diagram as a single self-contained HTML file with inline SVG, following this design \
        system exactly. Use the user's language for every label. Use only the data and names the user gave; \
        do not invent figures. No JavaScript. External resources: only the Google Fonts link of the example.
        Reply with the complete HTML document only, from <!DOCTYPE html> to </html>.

        # Style guide
        \(library.reference("style-guide"))

        # Primitives
        \(library.reference("primitives-core"))

        # Visual type: \(type.name)
        \(library.reference("type-\(type.id)"))

        # Example of this type (structure and style to follow; replace all content)
        \(library.example(type.id))
        """
    }

    /// The HTML document in a reply, without scripts; nil when there is no SVG.
    static func document(in reply: String) -> String? {
        let start = reply.range(of: "<!DOCTYPE html", options: .caseInsensitive)
            ?? reply.range(of: "<html", options: .caseInsensitive)
        var html: String
        if let start, let end = reply.range(of: "</html>", options: [.caseInsensitive, .backwards]),
           start.lowerBound < end.upperBound {
            html = String(reply[start.lowerBound..<end.upperBound])
        } else if let svg = reply.range(of: "<svg", options: .caseInsensitive),
                  let end = reply.range(of: "</svg>", options: [.caseInsensitive, .backwards]) {
            html = "<!DOCTYPE html><html><body>" + reply[svg.lowerBound..<end.upperBound] + "</body></html>"
        } else {
            return nil
        }
        html = html.replacing(/(?is)<script\b.*?<\/script>/, with: "")
        return html.range(of: "<svg", options: .caseInsensitive) == nil ? nil : html
    }

    private func save(_ html: String, title: String) throws -> URL {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let stamp = Date.now.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
            .replacingOccurrences(of: ":", with: "")
        let slug = title.lowercased().folding(options: .diacriticInsensitive, locale: nil)
            .replacing(/[^a-z0-9]+/, with: "-").trimmingCharacters(in: CharacterSet(charactersIn: "-")).prefix(40)
        let file = output.appending(path: "\(stamp)-\(slug).html")
        try html.write(to: file, atomically: true, encoding: .utf8)
        return file
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
