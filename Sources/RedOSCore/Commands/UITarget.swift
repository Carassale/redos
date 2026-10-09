import Foundation

/// The name of an on-screen element as spoken: "il pulsante Salva" -> "Salva", "the Login button" -> "Login".
public enum UITarget {
    private static let leadingWords: Set<String> = [
        "il", "lo", "la", "l'", "i", "gli", "le", "sul", "sullo", "sulla", "sui", "su", "nel", "nella", "in",
        "pulsante", "bottone", "tasto", "link", "collegamento", "voce", "menu", "scheda", "campo", "casella",
        "the", "on", "button", "link", "menu", "tab", "item", "field", "box",
    ]
    private static let trailingWords: Set<String> = ["button", "link", "menu", "tab", "item", "field", "box"]
    /// Targets described by position or appearance need to look at the screen first; keys and the mouse
    /// are not elements.
    private static let descriptiveWords: Set<String> = [
        "primo", "prima", "secondo", "seconda", "terzo", "terza", "ultimo", "ultima", "blu", "rosso", "verde",
        "first", "second", "third", "last", "blue", "red", "green",
        "mouse", "puntatore", "pointer", "qui", "qua", "here", "destro", "sinistro", "right", "left",
        "invio", "enter", "return", "esc", "escape", "spazio", "space", "backspace", "canc", "delete",
    ]

    /// nil when nothing names an element, or the element is described rather than named.
    public static func clean(_ text: some StringProtocol) -> String? {
        var words = text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".!?")))
            .split(whereSeparator: \.isWhitespace).map(String.init)
        while let first = words.first, leadingWords.contains(first.lowercased()) { words.removeFirst() }
        while let last = words.last, trailingWords.contains(last.lowercased()) { words.removeLast() }
        let lowered = Set(words.map { $0.lowercased() })
        guard !words.isEmpty, lowered.isDisjoint(with: descriptiveWords),
              !words.joined().allSatisfy({ $0.isNumber || $0 == "," })
        else { return nil }
        return words.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”«»"))
    }
}
