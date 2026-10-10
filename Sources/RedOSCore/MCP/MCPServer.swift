import Foundation

/// A tool RedOS offers to MCP clients.
public struct MCPServerTool: Sendable {
    public let name: String
    public let description: String
    public let inputSchema: JSONValue
    public let isReadOnly: Bool
    public let handler: @Sendable (JSONValue) async -> MCPToolResult

    public init(
        name: String, description: String, inputSchema: JSONValue, isReadOnly: Bool,
        handler: @escaping @Sendable (JSONValue) async -> MCPToolResult
    ) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.isReadOnly = isReadOnly
        self.handler = handler
    }
}

public struct MCPToolResult: Sendable, Equatable {
    public let text: String
    public let isError: Bool

    public init(_ text: String, isError: Bool = false) {
        self.text = text
        self.isError = isError
    }
}

/// The Model Context Protocol subset RedOS serves: initialize, ping, tools/list, tools/call.
public struct MCPServer: Sendable {
    public static let protocolVersion = "2025-06-18"
    static let supportedVersions: Set<String> = ["2025-06-18", "2025-03-26", "2024-11-05"]

    let name: String
    let version: String
    let instructions: String
    let tools: [MCPServerTool]

    public init(name: String, version: String, instructions: String, tools: [MCPServerTool]) {
        self.name = name
        self.version = version
        self.instructions = instructions
        self.tools = tools
    }

    /// The JSON-RPC response, or nil for notifications.
    public func handle(_ message: JSONValue) async -> JSONValue? {
        guard let method = message["method"]?.string else {
            return Self.error(message["id"] ?? .null, code: -32600, "Invalid request")
        }
        guard let id = message["id"] else { return nil }
        let params = message["params"] ?? .object([:])
        switch method {
        case "initialize":
            let requested = params["protocolVersion"]?.string ?? Self.protocolVersion
            let version = Self.supportedVersions.contains(requested) ? requested : Self.protocolVersion
            return Self.result(id, .object([
                "protocolVersion": .string(version),
                "capabilities": .object(["tools": .object([:])]),
                "serverInfo": .object(["name": .string(name), "version": .string(version)]),
                "instructions": .string(instructions),
            ]))
        case "ping":
            return Self.result(id, .object([:]))
        case "tools/list":
            return Self.result(id, .object(["tools": .array(tools.map(Self.describe))]))
        case "tools/call":
            guard let toolName = params["name"]?.string, let tool = tools.first(where: { $0.name == toolName }) else {
                return Self.error(id, code: -32602, "Unknown tool")
            }
            let output = await tool.handler(params["arguments"] ?? .object([:]))
            return Self.result(id, .object([
                "content": .array([.object(["type": "text", "text": .string(output.text)])]),
                "isError": .bool(output.isError),
            ]))
        default:
            return Self.error(id, code: -32601, "Method not found")
        }
    }

    private static func describe(_ tool: MCPServerTool) -> JSONValue {
        .object([
            "name": .string(tool.name),
            "description": .string(tool.description),
            "inputSchema": tool.inputSchema,
            "annotations": .object(["readOnlyHint": .bool(tool.isReadOnly)]),
        ])
    }

    static func result(_ id: JSONValue, _ result: JSONValue) -> JSONValue {
        .object(["jsonrpc": "2.0", "id": id, "result": result])
    }

    static func error(_ id: JSONValue, code: Int, _ message: String) -> JSONValue {
        .object([
            "jsonrpc": "2.0", "id": id,
            "error": .object(["code": .number(Double(code)), "message": .string(message)]),
        ])
    }
}

/// Streamable HTTP for `MCPServer` on 127.0.0.1: JSON responses only, no event streams.
public struct MCPHTTPEndpoint: Sendable {
    let server: MCPServer
    let token: String
    let port: UInt16

    public init(server: MCPServer, token: String, port: UInt16) {
        self.server = server
        self.token = token
        self.port = port
    }

    public func respond(_ request: HTTPRequest) async -> HTTPResponse {
        guard request.path.split(separator: "?").first == "/mcp" else { return HTTPResponse(status: 404) }
        // Browsers always send Origin: refusing it keeps web pages (and DNS rebinding) out.
        guard request.headers["origin"] == nil else { return HTTPResponse(status: 403) }
        let host = request.headers["host"] ?? ""
        guard ["127.0.0.1:\(port)", "localhost:\(port)", "[::1]:\(port)"].contains(host) else {
            return HTTPResponse(status: 403)
        }
        guard Self.matches(request.headers["authorization"] ?? "", "Bearer \(token)") else {
            return HTTPResponse(status: 401, headers: ["WWW-Authenticate": "Bearer"])
        }
        guard request.method == "POST" else { return HTTPResponse(status: 405, headers: ["Allow": "POST"]) }
        guard let message = try? JSONDecoder().decode(JSONValue.self, from: request.body) else {
            return Self.json(MCPServer.error(.null, code: -32700, "Parse error"), status: 400)
        }
        guard let response = await server.handle(message) else { return HTTPResponse(status: 202) }
        return Self.json(response)
    }

    private static func json(_ value: JSONValue, status: Int = 200) -> HTTPResponse {
        HTTPResponse(
            status: status, headers: ["Content-Type": "application/json"],
            body: (try? JSONEncoder().encode(value)) ?? Data()
        )
    }

    /// Constant-time comparison, so response timing does not reveal the token.
    static func matches(_ given: String, _ expected: String) -> Bool {
        let lhs = Array(given.utf8), rhs = Array(expected.utf8)
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
