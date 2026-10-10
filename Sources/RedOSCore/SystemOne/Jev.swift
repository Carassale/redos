import Foundation

/// Subset of the Jev System One protocol (typed `choice` questions) used to route commands.
public struct JevOption: Sendable, Equatable {
    public let label: String
    public let description: String

    public init(label: String, description: String) {
        self.label = label
        self.description = description
    }
}

public struct JevChoiceQuestion: Sendable, Equatable {
    public let instructions: String
    public let options: [JevOption]

    public init(instructions: String, options: [JevOption]) {
        self.instructions = instructions
        self.options = options
    }
}

public struct JevChoiceAnswer: Decodable, Sendable, Equatable {
    public let choice: String
    public let probabilities: [String: Double]
    public let confidence: Double

    public var probability: Double { probabilities[choice] ?? 0 }

    public init(choice: String, probabilities: [String: Double], confidence: Double) {
        self.choice = choice
        self.probabilities = probabilities
        self.confidence = confidence
    }

    /// Normalizes raw probability mass over `labels`; confidence is 1 - normalized entropy, as in Jev.
    public init(normalizing mass: [String: Double], labels: [String]) throws(SystemOneError) {
        let total = labels.reduce(0) { $0 + max(mass[$1] ?? 0, 0) }
        guard total > 0 else { throw .noDecision }
        var probabilities: [String: Double] = [:]
        for label in labels {
            probabilities[label] = max(mass[label] ?? 0, 0) / total
        }
        let entropy = probabilities.values.filter { $0 > 0 }.reduce(0) { $0 - $1 * log($1) }
        self.choice = labels.max { probabilities[$0, default: 0] < probabilities[$1, default: 0] } ?? labels[0]
        self.probabilities = probabilities
        self.confidence = labels.count > 1 ? 1 - entropy / log(Double(labels.count)) : 1
    }
}

public protocol SystemOne: Sendable {
    func choose(_ question: JevChoiceQuestion, state: String) async throws -> JevChoiceAnswer

    /// Conversation that produced `answer`; a follow-up call to the same model can reuse it as a cached prefix.
    func transcript(for question: JevChoiceQuestion, state: String, answer: JevChoiceAnswer) -> [ChatMessage]
}

extension SystemOne {
    public func transcript(for question: JevChoiceQuestion, state: String, answer: JevChoiceAnswer) -> [ChatMessage] {
        []
    }
}

public enum SystemOneError: Error, Equatable, LocalizedError {
    case unavailable(String)
    case http(Int)
    case noDecision
    case tooManyOptions

    public var errorDescription: String? {
        switch self {
        case .unavailable(let reason): String(localized: "System One unavailable: \(reason)")
        case .http(let status): String(localized: "System One returned HTTP \(status)")
        case .noDecision: String(localized: "System One gave no usable answer.")
        case .tooManyOptions: String(localized: "Too many options for System One.")
        }
    }
}
