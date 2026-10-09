import Foundation

/// Deterministic "level 0" parser for frequent commands: no model, no latency.
public struct FastPathParser: Sendable {
    public struct Vocabulary: Sendable {
        public var openApp: [String]
        public var openURL: [String]
        public var quitApp: [String]
        public var typeText: [String]
        public var scroll: [String]
        public var directions: [String: String]
        public var click: [String]
        public var moveMouse: [String]
        /// Words that chain steps ("and", "poi"): such commands go to the models instead.
        public var connectors: [String]
        /// Trailing courtesy ("please") dropped from app names.
        public var courtesies: [String]

        public init(
            openApp: [String], quitApp: [String], typeText: [String], scroll: [String],
            directions: [String: String], click: [String], moveMouse: [String],
            openURL: [String] = [], connectors: [String] = [], courtesies: [String] = []
        ) {
            self.openApp = openApp
            self.openURL = openURL
            self.quitApp = quitApp
            self.typeText = typeText
            self.scroll = scroll
            self.directions = directions
            self.click = click
            self.moveMouse = moveMouse
            self.connectors = connectors
            self.courtesies = courtesies
        }
    }

    public var vocabularies: [Vocabulary]

    public init(vocabularies: [Vocabulary] = [.english, .italian]) {
        self.vocabularies = vocabularies
    }

    public func parse(_ input: String) -> ActionRequest? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return vocabularies.lazy.compactMap { parse(text, with: $0) }.first
    }

    private func parse(_ text: String, with vocabulary: Vocabulary) -> ActionRequest? {
        // Typing first, so "type open safari" types the text instead of opening an app.
        if let rest = remainder(of: text, after: vocabulary.typeText) {
            return ActionRequest("text.type", ["text": unquoted(rest)])
        }
        if let rest = remainder(of: text, after: vocabulary.openURL), WebAddress.url(from: rest) != nil {
            return ActionRequest("url.open", ["url": rest])
        }
        if let rest = remainder(of: text, after: vocabulary.openApp) {
            return openRequest(rest, vocabulary)
        }
        if let rest = remainder(of: text, after: vocabulary.quitApp) {
            return appName(rest, vocabulary).map { ActionRequest("app.quit", ["name": $0]) }
        }
        if let rest = remainder(of: text, after: vocabulary.moveMouse) {
            return coordinates(in: rest).map { ActionRequest("mouse.move", ["x": String($0), "y": String($1)]) }
        }
        if let rest = remainder(of: text, after: vocabulary.click, allowEmpty: true) {
            if rest.isEmpty { return ActionRequest("mouse.click") }
            return coordinates(in: rest).map { ActionRequest("mouse.click", ["x": String($0), "y": String($1)]) }
        }
        if let rest = remainder(of: text, after: vocabulary.scroll, allowEmpty: true) {
            return scrollRequest(rest, directions: vocabulary.directions)
        }
        return nil
    }

    /// "apri Safari" opens the app, "apri google.com" the website.
    private func openRequest(_ rest: String, _ vocabulary: Vocabulary) -> ActionRequest? {
        guard let name = appName(rest, vocabulary) else { return nil }
        return WebAddress.url(from: name) == nil
            ? ActionRequest("app.open", ["name": name])
            : ActionRequest("url.open", ["url": name])
    }

    private func scrollRequest(_ rest: String, directions: [String: String]) -> ActionRequest? {
        var arguments = ["direction": "down"]
        var tail = rest
        for word in directions.keys.sorted(by: { $0.count > $1.count }) {
            if let after = remainder(of: rest, after: [word], allowEmpty: true) {
                arguments["direction"] = directions[word]
                tail = after
                break
            }
        }
        if !tail.isEmpty {
            guard let amount = tail.split(whereSeparator: { !$0.isNumber }).lazy.compactMap({ Int($0) }).first
            else { return nil }
            arguments["amount"] = String(amount)
        }
        return ActionRequest("scroll", arguments)
    }

    private static let matchOptions: String.CompareOptions = [.anchored, .caseInsensitive, .diacriticInsensitive]

    /// Text after the longest matching prefix, which must end on a word boundary.
    private func remainder(of text: String, after prefixes: [String], allowEmpty: Bool = false) -> String? {
        for prefix in prefixes.sorted(by: { $0.count > $1.count }) {
            guard let range = text.range(of: prefix, options: Self.matchOptions) else { continue }
            let rest = text[range.upperBound...]
            if rest.isEmpty {
                if allowEmpty { return "" }
                continue
            }
            guard rest.first?.isWhitespace == true else { continue }
            let trimmed = rest.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty && !allowEmpty { continue }
            return trimmed
        }
        return nil
    }

    private func appName(_ rest: String, _ vocabulary: Vocabulary) -> String? {
        var name = rest
        for courtesy in vocabulary.courtesies.sorted(by: { $0.count > $1.count }) {
            if let range = name.range(of: courtesy, options: [.backwards, .anchored, .caseInsensitive]) {
                name = name[..<range.lowerBound].trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
                break
            }
        }
        let words = Set(name.lowercased().split(whereSeparator: \.isWhitespace).map(String.init))
        guard !name.isEmpty, !name.contains(","), words.isDisjoint(with: vocabulary.connectors) else { return nil }
        return unquoted(name)
    }

    private func coordinates(in text: String) -> (Int, Int)? {
        let numbers = text.split { !$0.isNumber }.compactMap { Int($0) }
        guard numbers.count == 2 else { return nil }
        return (numbers[0], numbers[1])
    }

    private func unquoted(_ text: String) -> String {
        let quotes: Set<Character> = ["\"", "'", "“", "”", "«", "»"]
        guard text.count >= 2, let first = text.first, let last = text.last,
              quotes.contains(first), quotes.contains(last)
        else { return text }
        return String(text.dropFirst().dropLast())
    }
}

extension FastPathParser.Vocabulary {
    public static let english = Self(
        openApp: ["open", "launch", "start"],
        quitApp: ["quit", "close"],
        typeText: ["type", "write"],
        scroll: ["scroll"],
        directions: ["up": "up", "down": "down", "left": "left", "right": "right"],
        click: ["click", "click at"],
        moveMouse: ["move mouse to", "move the mouse to", "move mouse", "move the mouse"],
        openURL: ["go to", "browse to", "navigate to", "open website", "open the website", "open the site"],
        connectors: ["and", "then"],
        courtesies: ["please", "for me"]
    )

    public static let italian = Self(
        openApp: ["apri", "avvia", "lancia"],
        quitApp: ["chiudi", "esci da"],
        typeText: ["scrivi", "digita"],
        scroll: ["scrolla", "scorri"],
        directions: [
            "su": "up", "in alto": "up", "giù": "down", "in basso": "down",
            "a sinistra": "left", "sinistra": "left", "a destra": "right", "destra": "right",
        ],
        click: ["clicca", "clic", "click", "clicca a", "clicca in"],
        moveMouse: ["muovi il mouse a", "muovi il mouse su", "muovi il mouse", "sposta il mouse a", "sposta il mouse"],
        openURL: ["vai su", "vai a", "naviga su", "naviga a", "apri il sito"],
        connectors: ["e", "poi", "quindi"],
        courtesies: ["per favore", "per piacere", "grazie"]
    )
}
