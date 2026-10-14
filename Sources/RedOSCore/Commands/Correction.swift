import Foundation

/// What the user means when they speak while RedOS is working.
public enum Correction: Sendable, Equatable {
    /// "fermati", "stop".
    case stop
    /// "no, a Luca", "anzi in Chrome": the task changes.
    case modify
    /// "e poi apri Slack": one more request once the task is done.
    case add(String)
    /// Talk not meant for RedOS.
    case unrelated
}

/// Recognizes corrections: clear phrases by rule, the rest with a System One choice (Jev first, then the local
/// model). Unsure means unrelated: RedOS keeps working.
public struct CorrectionClassifier: Sendable {
    static let minimumProbability = 0.6
    private static let stopPhrases: Set<String> = [
        "stop", "fermati", "ferma", "fermo", "basta", "annulla", "aspetta", "lascia stare", "lascia perdere",
        "ferma tutto", "stop stop", "no", "no no", "cancel", "wait", "hold on", "never mind", "stop it",
    ]
    private static let additionPrefixes = [
        "e poi anche ", "e poi ", "poi anche ", "poi ", "dopo ", "e anche ", "aggiungi anche ", "aggiungi ",
        "and then also ", "and then ", "then ", "also ", "after that ", "and also ",
    ]
    private static let modificationPrefixes = [
        "no ", "anzi ", "invece ", "non ", "volevo dire ", "intendevo ", "cambia ", "meglio ",
        "actually ", "instead ", "i meant ", "not ", "rather ",
    ]

    private let deciders: [any SystemOne]

    /// `deciders` are tried in order until one answers.
    public init(deciders: [any SystemOne]) {
        self.deciders = deciders
    }

    public func classify(_ utterance: String, task: String, done: [String]) async -> Correction {
        if let correction = Self.rule(for: utterance) { return correction }
        let state = "Task RedOS is working on: \(task)\n"
            + "Steps already started: \(done.isEmpty ? "none" : done.joined(separator: "; "))\n"
            + "The user just said: \(utterance)"
        for decider in deciders {
            guard let answer = try? await decider.choose(Self.question, state: state) else { continue }
            guard answer.probability >= Self.minimumProbability else { return .unrelated }
            switch answer.choice {
            case "stop": return .stop
            case "modify": return .modify
            case "add": return .add(Self.request(fromAddition: utterance))
            default: return .unrelated
            }
        }
        return .unrelated
    }

    static let question = JevChoiceQuestion(
        instructions: "RedOS is carrying out a task on the user's Mac and the user just spoke."
            + " What does the user want RedOS to do with the task?",
        options: [
            JevOption(label: "stop", description: "Stop the task now (e.g. \"wait\", \"leave it\")."),
            JevOption(
                label: "modify",
                description: "Change the task: a different target, text, app or detail (e.g. \"no, to Luca\")."
            ),
            JevOption(label: "add", description: "Do something more after the task (e.g. \"then open Slack\")."),
            JevOption(
                label: "unrelated",
                description: "Not about the task: talking to someone else, thinking aloud, noise."
            ),
        ]
    )

    /// Clear cases without a model.
    static func rule(for utterance: String) -> Correction? {
        let text = normalized(utterance)
        if stopPhrases.contains(text) { return .stop }
        if additionPrefixes.contains(where: { text.hasPrefix($0) }) { return .add(request(fromAddition: utterance)) }
        if modificationPrefixes.contains(where: { text.hasPrefix($0) }) { return .modify }
        return nil
    }

    /// "e poi apri Slack" -> "apri Slack".
    static func request(fromAddition utterance: String) -> String {
        let text = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        // Same length as `text`: the prefix can be cut by count.
        let lowered = text.lowercased().replacingOccurrences(of: ",", with: " ")
        guard let prefix = additionPrefixes.first(where: { lowered.hasPrefix($0) }) else { return text }
        return String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces.union(.punctuationCharacters))
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: ",", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    }
}
