import Foundation

public struct Diagram: Sendable, Equatable {
    public let title: String
    /// Mermaid code.
    public let source: String
    /// The diagram as a page for the browser (Mermaid from its CDN).
    public let file: URL
    /// Markdown written with the diagram when the request also asks to explain.
    public var explanation: String?
}

public enum DiagramError: Error, LocalizedError, Equatable {
    case noDiagram

    public var errorDescription: String? {
        String(localized: "The model did not produce a diagram. Try a cloud provider for diagrams.")
    }
}

/// Draws a diagram as Mermaid code, with an explanation when asked: one reply instead of a hand-made SVG page.
public struct DiagramDesigner: Sendable {
    private let client: any ChatCompleting
    private let output: URL

    public init(
        client: any ChatCompleting, output: URL = URL.applicationSupportDirectory.appending(path: "RedOS/Diagrams")
    ) {
        self.client = client
        self.output = output
    }

    static let prompt = """
        You draw one diagram as Mermaid 11 code. Pick the kind that fits: flowchart (processes, decisions), \
        sequenceDiagram (messages between actors), stateDiagram-v2, classDiagram, erDiagram, timeline, gantt, \
        pie (shares), xychart-beta (bars or lines of numbers), mindmap, quadrantChart, journey.
        Rules: every label in the user's language; only the data and names the user gave, never invent figures; \
        put labels with punctuation in double quotes, e.g. A["Verifica (2FA)"]; no style, classDef, click or \
        %%{init} lines; at most 30 nodes.
        If the request also asks to explain, describe or tell about the subject, first write the explanation in \
        Markdown in the user's language (at most 200 words, short paragraphs or a list), then the diagram. \
        Otherwise write only the diagram, with no text around it.
        The diagram goes in one ```mermaid code block whose first line is:
        %% title: <short title in the user's language>
        """

    static let kinds = [
        "flowchart", "graph", "sequenceDiagram", "stateDiagram", "classDiagram", "erDiagram", "timeline", "gantt",
        "pie", "xychart", "mindmap", "quadrantChart", "journey", "gitGraph", "sankey", "block",
    ]

    /// A line that opens a diagram: its first word is a kind, like `flowchart` or `stateDiagram-v2`.
    static func startsDiagram(_ line: Substring) -> Bool {
        let word = line.drop { $0.isWhitespace }.prefix { !$0.isWhitespace }
        return kinds.contains { word == $0 || word.hasPrefix($0 + "-") }
    }

    /// `request` is what the user said, when `description` (what to draw) was written by the planner.
    public func draw(_ description: String, request: String? = nil) async throws -> Diagram {
        await ActivityReporter.report(.drawing)
        let message = request.map { $0 == description ? description : "Request: \($0)\nWhat to draw: \(description)" }
            ?? description
        let response = try await client.chat(
            [.system(Self.prompt), .user(message)], format: nil, maxTokens: 3000, topLogprobs: nil
        )
        guard let reply = MermaidReply(response.message.content) else { throw DiagramError.noDiagram }
        let name = reply.title ?? String(localized: "Diagram")
        let page = MermaidPage.html(
            reply.source, title: name, scriptURL: "https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.min.js"
        )
        return Diagram(
            title: name, source: reply.source, file: try save(page, title: name), explanation: reply.explanation
        )
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

/// A reply split into its Mermaid diagram (without init directives), its title and the prose around it.
struct MermaidReply: Equatable {
    let title: String?
    let source: String
    let explanation: String?

    init?(_ reply: String) {
        var reader = Reader()
        for line in reply.split(separator: "\n", omittingEmptySubsequences: false) { reader.read(line) }
        reader.finish()
        guard let diagram = reader.diagram else { return nil }
        title = reader.title
        source = diagram.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        explanation = reader.prose.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    private struct Reader {
        var title: String?
        var prose: [Substring] = []
        var diagram: [Substring]?
        /// The open code block, from its fence.
        var block: [Substring]?

        mutating func read(_ line: Substring) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let match = trimmed.firstMatch(of: /^%%\s*title:\s*(.+)$/) {
                title = title ?? String(match.1).trimmingCharacters(in: .whitespaces).nilIfEmpty
            } else if trimmed.hasPrefix("%%{") {
                return
            } else if trimmed.hasPrefix("```") {
                if block == nil { block = [line] } else { close(with: line) }
            } else if block != nil {
                block?.append(line)
            } else {
                prose.append(line)
            }
        }

        /// The first block holding a diagram is the diagram; other blocks (code examples) stay in the prose.
        mutating func close(with fence: Substring?) {
            guard let open = block else { return }
            block = nil
            let body = open.dropFirst()
            if diagram == nil, let start = body.firstIndex(where: DiagramDesigner.startsDiagram) {
                diagram = Array(body[start...])
            } else {
                prose += open + (fence.map { [$0] } ?? [])
            }
        }

        /// A cut-off block still counts; in a reply without fences the diagram starts at its first line.
        mutating func finish() {
            close(with: nil)
            guard diagram == nil, let start = prose.firstIndex(where: DiagramDesigner.startsDiagram) else { return }
            diagram = Array(prose[start...])
            prose = Array(prose[..<start])
        }
    }
}
