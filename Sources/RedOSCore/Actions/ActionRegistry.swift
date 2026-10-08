public struct ActionRegistry: Sendable {
    private let actions: [String: any Action]

    public init(_ actions: [any Action]) {
        self.actions = Dictionary(actions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    public var all: [any Action] {
        actions.values.sorted { $0.id < $1.id }
    }

    public func action(for id: String) -> (any Action)? {
        actions[id]
    }

    /// Strict validation: requests may come from a model, so unknown or malformed arguments are rejected.
    public func validate(_ request: ActionRequest) throws(ActionError) -> any Action {
        guard let action = actions[request.actionID] else { throw .unknownAction(request.actionID) }

        let known = Set(action.parameters.map(\.name))
        if let unknown = request.arguments.keys.sorted().first(where: { !known.contains($0) }) {
            throw .invalidArgument(unknown, request.arguments[unknown] ?? "")
        }

        for parameter in action.parameters {
            guard let value = request.arguments[parameter.name], !value.isEmpty else {
                if parameter.isRequired { throw .missingArgument(parameter.name) }
                continue
            }
            switch parameter.kind {
            case .string:
                break
            case .integer:
                guard Int(value) != nil else { throw .invalidArgument(parameter.name, value) }
            case .oneOf(let options):
                guard options.contains(value) else { throw .invalidArgument(parameter.name, value) }
            }
        }
        return action
    }
}
