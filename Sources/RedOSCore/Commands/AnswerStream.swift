import Foundation

/// The final answer as the model writes it, so the voice can start before the answer is complete.
public enum AnswerStream {
    /// Set by whoever presents the answer: receives the text as it arrives, in order.
    @TaskLocal public static var sink: AsyncStream<String>.Continuation?
    /// Set only around the call that writes the final answer (never plans or JSON); streaming clients send here.
    @TaskLocal static var writing: AsyncStream<String>.Continuation?
}

/// Cuts streamed Markdown into lines and sentences that can be spoken on their own.
public struct SpokenSentences: Sendable {
    private var buffer = ""

    public init() {}

    /// The lines and sentences completed by `text`; the rest waits for more text.
    public mutating func append(_ text: String) -> [String] {
        buffer += text
        var pieces: [String] = []
        while let end = Self.boundary(in: buffer) {
            let piece = buffer[..<end].trimmingCharacters(in: .whitespacesAndNewlines)
            buffer = String(buffer[end...])
            if !piece.isEmpty { pieces.append(piece) }
        }
        return pieces
    }

    /// What is left once the answer is complete.
    public mutating func finish() -> String? {
        defer { buffer = "" }
        let rest = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        return rest.isEmpty ? nil : rest
    }

    /// After a newline, or after ". ", "! ", "? " outside bold text and links ("1. " is a list number).
    private static func boundary(in text: String) -> String.Index? {
        var bold = false
        var link = 0
        var previous: Character?
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            if character == "\n" { return next }
            if character == "*", next < text.endIndex, text[next] == "*" {
                bold.toggle()
                previous = character
                index = text.index(after: next)
                continue
            }
            if character == "[" {
                link += 1
            } else if character == "]", link > 0 {
                link -= 1
            } else if ".!?".contains(character), !bold, link == 0, previous?.isNumber != true,
                      next < text.endIndex, text[next] == " " {
                return next
            }
            previous = character
            index = next
        }
        return nil
    }
}
