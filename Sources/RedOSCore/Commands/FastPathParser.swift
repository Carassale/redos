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
        /// "premi Salva", "click on Login": an on-screen element by name.
        public var press: [String]
        /// "scrivi Mario nel campo Nome": typing into a named field.
        public var fillMarkers: [String]
        /// When set, the field name must end with one of these ("in the Search field").
        public var fillSuffixes: [String]
        /// Whole commands that read the frontmost window.
        public var read: [String]
        /// "esegui il comando ls".
        public var shell: [String]

        public init(
            openApp: [String], quitApp: [String], typeText: [String], scroll: [String],
            directions: [String: String], click: [String], moveMouse: [String],
            openURL: [String] = [], connectors: [String] = [], courtesies: [String] = [],
            press: [String] = [], fillMarkers: [String] = [], fillSuffixes: [String] = [],
            read: [String] = [], shell: [String] = []
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
            self.press = press
            self.fillMarkers = fillMarkers
            self.fillSuffixes = fillSuffixes
            self.read = read
            self.shell = shell
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

    /// A composite command whose every part is a fast-path command, e.g. "apri Chrome e vai su google.com".
    public func parsePlan(_ input: String) -> [ActionRequest]? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        for vocabulary in vocabularies {
            let parts = split(text, on: vocabulary.connectors)
            guard parts.count > 1, parts.count <= 6 else { continue }
            let requests = parts.compactMap(parse)
            if requests.count == parts.count {
                return PlanSimplifier.simplify(requests)
            }
        }
        return nil
    }

    /// Splits on commas and whole-word connectors ("e", "poi", "and then").
    private func split(_ text: String, on connectors: [String]) -> [String] {
        let words = connectors.sorted { $0.count > $1.count }
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "|")
        let pattern = "\\s*,\\s*(?:(?:\(words))\\s+)?|\\s+(?:\(words))\\s+"
        guard !words.isEmpty, let separator = try? Regex(pattern) else { return [text] }
        return text.split(separator: separator.ignoresCase())
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func parse(_ text: String, with vocabulary: Vocabulary) -> ActionRequest? {
        if let request = screenRequest(text, vocabulary) { return request }
        // Typing first, so "type open safari" types the text instead of opening an app.
        if let rest = remainder(of: text, after: vocabulary.typeText) {
            return fillRequest(rest, vocabulary) ?? ActionRequest("text.type", ["text": unquoted(rest)])
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

    /// Screen reading, named elements and shell commands.
    private func screenRequest(_ text: String, _ vocabulary: Vocabulary) -> ActionRequest? {
        let sentence = text.trimmingCharacters(in: CharacterSet(charactersIn: " ?!."))
        if vocabulary.read.contains(where: { $0.compare(sentence, options: Self.matchOptions) == .orderedSame }) {
            return ActionRequest("ui.read")
        }
        if let rest = remainder(of: text, after: vocabulary.shell) {
            // "esegui il comando rapido Casa" is a Shortcut, not a shell command line.
            let words = rest.split(separator: " ", maxSplits: 1).map(String.init)
            if let first = words.first?.lowercased(), ["rapido", "shortcut"].contains(first), words.count == 2 {
                return ActionRequest("shortcut.run", ["name": unquoted(words[1])])
            }
            return ActionRequest("shell.run", ["command": unquoted(rest)])
        }
        if let rest = remainder(of: text, after: vocabulary.press), let target = UITarget.clean(rest) {
            return ActionRequest("ui.press", ["target": target])
        }
        return nil
    }

    private func fillRequest(_ rest: String, _ vocabulary: Vocabulary) -> ActionRequest? {
        for marker in vocabulary.fillMarkers {
            guard let range = rest.range(of: " \(marker) ", options: [.caseInsensitive, .backwards]) else { continue }
            let field = rest[range.upperBound...].lowercased()
            guard vocabulary.fillSuffixes.isEmpty || vocabulary.fillSuffixes.contains(where: field.hasSuffix),
                  let target = UITarget.clean(rest[range.upperBound...])
            else { continue }
            return ActionRequest("ui.fill", ["target": target, "text": unquoted(String(rest[..<range.lowerBound]))])
        }
        return nil
    }

    private static let menuWords: Set<String> = ["menu", "scheda", "voce", "tab"]

    /// "apri Safari" opens the app, "apri google.com" the website, "apri il menu File" the menu.
    private func openRequest(_ rest: String, _ vocabulary: Vocabulary) -> ActionRequest? {
        guard let name = appName(rest, vocabulary) else { return nil }
        let words = Set(name.lowercased().split(whereSeparator: \.isWhitespace).map(String.init))
        if !words.isDisjoint(with: Self.menuWords) {
            return UITarget.clean(name).map { ActionRequest("ui.press", ["target": $0]) }
        }
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
        connectors: ["and then", "and", "then"],
        courtesies: ["please", "for me"],
        press: ["click on", "click the", "press the", "press", "tap on", "hit the"],
        fillMarkers: ["into the", "in the"],
        fillSuffixes: ["field", "box"],
        read: [
            "read the screen", "read the window", "read the page", "read this page", "read me the screen",
            "what's on the screen", "what is on the screen", "what's on screen",
        ],
        shell: ["run the command", "run command", "run in the terminal", "run in terminal"]
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
        openURL: [
            "vai su", "vai a", "vai sul sito", "vai al sito", "naviga su", "naviga a", "naviga sul sito",
            "apri il sito",
        ],
        connectors: ["e poi", "e", "poi", "quindi"],
        courtesies: ["per favore", "per piacere", "grazie"],
        press: [
            "premi", "premi su", "premi sul", "clicca", "clicca su", "clicca sul", "clicca sulla", "clicca sullo",
            "fai clic su", "fai clic sul", "fai click su", "fai click sul", "pigia",
        ],
        fillMarkers: ["nel campo", "nella casella", "nel riquadro"],
        read: [
            "leggi lo schermo", "leggimi lo schermo", "leggi la finestra", "leggimi la finestra",
            "leggi la pagina", "leggimi la pagina", "cosa c'è sullo schermo", "cosa c'è sulla pagina",
        ],
        shell: ["esegui il comando", "esegui nel terminale", "lancia il comando", "esegui comando"]
    )
}
