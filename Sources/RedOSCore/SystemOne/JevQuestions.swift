import Foundation

/// A typed Jev question; several are asked about the same state in one request.
public enum JevQuestion: Sendable, Equatable {
    /// One option out of up to 255, each with a short description.
    case choice(instructions: String, options: [JevOption])
    /// Probability that a statement is true.
    case noul(instructions: String)
    /// Expected level on an ordered rubric (up to 10 levels).
    case score(instructions: String, levels: [String])

    var json: JSONValue {
        switch self {
        case .choice(let instructions, let options):
            let criteria = Dictionary(
                options.map { ($0.label, JSONValue.string($0.description)) }, uniquingKeysWith: { first, _ in first }
            )
            return .object([
                "type": "choice", "instructions": .string(instructions), "criteria": .object(criteria),
            ])
        case .noul(let instructions):
            return .object(["type": "noul", "instructions": .string(instructions)])
        case .score(let instructions, let levels):
            return .object([
                "type": "score", "instructions": .string(instructions),
                "criteria": .array(levels.map(JSONValue.string)),
            ])
        }
    }
}

/// One answer: `choice` for choices, `noul` for nouls, `score` for scores.
public struct JevAnswer: Decodable, Sendable, Equatable {
    public let choice: String?
    public let noul: Double?
    public let score: Double?
    public let probabilities: [String: Double]
    public let confidence: Double?

    /// Probability of the chosen option (choices), of "yes" (nouls).
    public var probability: Double {
        if let choice { return probabilities[choice] ?? 0 }
        return noul ?? 0
    }

    public init(
        choice: String? = nil, noul: Double? = nil, score: Double? = nil,
        probabilities: [String: Double] = [:], confidence: Double? = nil
    ) {
        self.choice = choice
        self.noul = noul
        self.score = score
        self.probabilities = probabilities
        self.confidence = confidence
    }

    private enum CodingKeys: String, CodingKey {
        case choice, noul, score, probabilities, confidence
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        choice = try container.decodeIfPresent(String.self, forKey: .choice)
        noul = try container.decodeIfPresent(Double.self, forKey: .noul)
        score = try container.decodeIfPresent(Double.self, forKey: .score)
        confidence = try container.decodeIfPresent(Double.self, forKey: .confidence)
        // Scores may list probabilities by level index: only the keyed form is kept.
        probabilities = (try? container.decodeIfPresent([String: Double].self, forKey: .probabilities)) ?? [:]
    }
}

/// Asks several typed questions about one state at once (Jev's `/v1/systemone`).
public protocol JevDeciding: Sendable {
    func decide(state: String, questions: [String: JevQuestion]) async throws -> [String: JevAnswer]
}
