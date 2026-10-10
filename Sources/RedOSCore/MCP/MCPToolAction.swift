import Foundation

/// A tool of an external MCP server, usable in System Two plans like a built-in action.
public struct MCPToolAction: ReportingAction {
    public let id: String
    public let summary: String
    public let risk: RiskLevel
    public let parameters: [ActionParameter]
    let tool: MCPToolInfo
    let client: MCPStdioClient

    public init(server: String, tool: MCPToolInfo, client: MCPStdioClient) {
        id = "mcp.\(Self.identifier(server)).\(Self.identifier(tool.name))"
        summary = "[MCP \(server)] " + tool.description.split(separator: "\n").prefix(2).joined(separator: " ")
        // Read-only tools run like safe actions; MCP tools are destructive unless the server says otherwise.
        risk = tool.isReadOnly ? .safe : tool.isDestructive ? .dangerous : .moderate
        parameters = Self.parameters(of: tool.inputSchema)
        self.tool = tool
        self.client = client
    }

    @MainActor public func report(_ arguments: ActionArguments) async throws -> String {
        let result: MCPToolResult
        do {
            result = try await client.call(tool.name, arguments: Self.arguments(arguments, schema: tool.inputSchema))
        } catch {
            throw ActionError.failed(error.localizedDescription)
        }
        if result.isError { throw ActionError.failed(result.text) }
        return result.text
    }

    static func identifier(_ name: String) -> String {
        String(name.map { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" ? $0 : "_" })
    }

    static func parameters(of schema: JSONValue) -> [ActionParameter] {
        guard case .object(let properties) = schema["properties"] else { return [] }
        var required = Set<String>()
        if case .array(let names) = schema["required"] { required = Set(names.compactMap(\.string)) }
        return properties.keys.sorted().map { name in
            let property = properties[name] ?? .null
            let description = property["description"]?.string ?? ""
            let kind: ActionParameter.Kind
            var hint = ""
            if case .array(let options) = property["enum"], !options.isEmpty, options.allSatisfy({ $0.string != nil }) {
                kind = .oneOf(options.compactMap(\.string))
            } else {
                switch property["type"]?.string {
                case "integer": kind = .integer
                case "number": (kind, hint) = (.string, " (number)")
                case "boolean": (kind, hint) = (.string, " (true or false)")
                case "array": (kind, hint) = (.string, " (JSON array)")
                case "object": (kind, hint) = (.string, " (JSON object)")
                default: kind = .string
                }
            }
            return ActionParameter(name, kind, required: required.contains(name), description: description + hint)
        }
    }

    /// Plan arguments are strings: converted to the JSON types the tool declares.
    static func arguments(_ arguments: ActionArguments, schema: JSONValue) -> [String: JSONValue] {
        arguments.reduce(into: [:]) { result, item in
            let type = schema["properties"]?[item.key]?["type"]?.string
            result[item.key] = switch type {
            case "integer", "number": Double(item.value).map(JSONValue.number) ?? .string(item.value)
            case "boolean": .bool(["true", "yes", "sì", "si", "1"].contains(item.value.lowercased()))
            case "array", "object":
                (try? JSONDecoder().decode(JSONValue.self, from: Data(item.value.utf8)))
                    ?? (type == "array" ? .array([.string(item.value)]) : .string(item.value))
            default: .string(item.value)
            }
        }
    }
}

/// The configured MCP servers: started once, restarted only when their configuration changes.
public actor MCPHub {
    public struct Status: Sendable, Equatable {
        public let name: String
        public let tools: [String]
        public let error: String?
    }

    private var clients: [String: (config: MCPServerConfig, client: MCPStdioClient)] = [:]
    private var actions: [String: [MCPToolAction]] = [:]
    private var errors: [String: String] = [:]

    public init() {}

    /// Connects the enabled servers of `configuration` and stops the others; failed servers are retried.
    public func update(_ configuration: MCPConfiguration) async {
        let enabled = configuration.mcpServers.filter { $0.value.disabled != true }
        for (name, entry) in clients where enabled[name] != entry.config || errors[name] != nil {
            await entry.client.stop()
            clients[name] = nil
            actions[name] = nil
            errors[name] = nil
        }
        struct Connection: Sendable {
            let name: String
            let config: MCPServerConfig
            let client: MCPStdioClient
            let result: Result<[MCPToolInfo], any Error>
        }
        await withTaskGroup(of: Connection.self) { group in
            for (name, config) in enabled where clients[name] == nil {
                group.addTask {
                    let client = MCPStdioClient(config: config)
                    let result: Result<[MCPToolInfo], any Error>
                    do {
                        result = .success(try await client.connect())
                    } catch {
                        await client.stop()
                        result = .failure(error)
                    }
                    return Connection(name: name, config: config, client: client, result: result)
                }
            }
            for await connection in group {
                let name = connection.name
                clients[name] = (connection.config, connection.client)
                switch connection.result {
                case .success(let tools):
                    actions[name] = tools.map { MCPToolAction(server: name, tool: $0, client: connection.client) }
                case .failure(let error):
                    errors[name] = error.localizedDescription
                }
            }
        }
    }

    public var allActions: [MCPToolAction] {
        actions.keys.sorted().flatMap { actions[$0] ?? [] }
    }

    public var statuses: [Status] {
        Set(clients.keys).union(errors.keys).sorted().map { name in
            Status(name: name, tools: actions[name]?.map(\.tool.name) ?? [], error: errors[name])
        }
    }
}
