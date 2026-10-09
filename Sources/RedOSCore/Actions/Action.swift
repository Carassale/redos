public enum RiskLevel: Int, Codable, Comparable, Sendable {
    case safe
    case moderate
    case dangerous

    public static func < (lhs: RiskLevel, rhs: RiskLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct ActionParameter: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case string
        case integer
        case oneOf([String])
        /// An http(s) address, see `WebAddress`.
        case webAddress
    }

    public let name: String
    public let kind: Kind
    public let isRequired: Bool
    public let isSensitive: Bool
    public let description: String

    public init(
        _ name: String, _ kind: Kind = .string, required: Bool = true, sensitive: Bool = false,
        description: String = ""
    ) {
        self.name = name
        self.kind = kind
        self.isRequired = required
        self.isSensitive = sensitive
        self.description = description
    }
}

public typealias ActionArguments = [String: String]

public struct ActionRequest: Sendable, Equatable {
    public let actionID: String
    public let arguments: ActionArguments

    public init(_ actionID: String, _ arguments: ActionArguments = [:]) {
        self.actionID = actionID
        self.arguments = arguments
    }
}

public protocol Action: Sendable {
    var id: String { get }
    /// English description used to build the decision catalog for the models.
    var summary: String { get }
    var risk: RiskLevel { get }
    var parameters: [ActionParameter] { get }
    var requiredPermissions: [Permission] { get }

    @MainActor func run(_ arguments: ActionArguments) async throws
}

extension Action {
    public var parameters: [ActionParameter] { [] }
    public var requiredPermissions: [Permission] { [] }
}

extension Dictionary where Key == String, Value == String {
    public func string(_ name: String) throws(ActionError) -> String {
        guard let value = self[name], !value.isEmpty else { throw .missingArgument(name) }
        return value
    }

    public func integer(_ name: String) -> Int? {
        self[name].flatMap { Int($0) }
    }
}
