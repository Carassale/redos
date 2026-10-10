import Foundation
import Testing
@testable import RedOSCore

struct MCPServerTests {
    private let server = MCPServer(
        name: "RedOS", version: "1.0", instructions: "Controls the Mac.",
        tools: [
            MCPServerTool(
                name: "echo", description: "Repeats the text.",
                inputSchema: .object(["type": "object"]), isReadOnly: true
            ) { arguments in MCPToolResult(arguments["text"]?.string ?? "") },
        ]
    )

    private static func request(_ method: String, _ params: JSONValue = .object([:]), id: Double = 1) -> JSONValue {
        .object(["jsonrpc": "2.0", "id": .number(id), "method": .string(method), "params": params])
    }

    @Test func initializes() async throws {
        let response = try #require(await server.handle(Self.request(
            "initialize", .object(["protocolVersion": "2025-03-26"])
        )))
        #expect(response["result"]?["protocolVersion"]?.string == "2025-03-26")
        #expect(response["result"]?["serverInfo"]?["name"]?.string == "RedOS")
        let unknownVersion = try #require(await server.handle(Self.request(
            "initialize", .object(["protocolVersion": "1999-01-01"])
        )))
        #expect(unknownVersion["result"]?["protocolVersion"]?.string == MCPServer.protocolVersion)
    }

    @Test func listsAndCallsTools() async throws {
        let list = try #require(await server.handle(Self.request("tools/list")))
        guard case .array(let tools) = list["result"]?["tools"] else {
            Issue.record("No tools")
            return
        }
        #expect(tools.first?["name"]?.string == "echo")
        #expect(tools.first?["annotations"]?["readOnlyHint"] == .bool(true))

        let call = try #require(await server.handle(Self.request(
            "tools/call", .object(["name": "echo", "arguments": .object(["text": "ciao"])])
        )))
        guard case .array(let content) = call["result"]?["content"] else {
            Issue.record("No content")
            return
        }
        #expect(content.first?["text"]?.string == "ciao")
        #expect(call["result"]?["isError"] == .bool(false))
    }

    @Test func handlesNotificationsAndErrors() async {
        let notification: JSONValue = .object(["jsonrpc": "2.0", "method": "notifications/initialized"])
        #expect(await server.handle(notification) == nil)
        let unknown = await server.handle(Self.request("resources/list"))
        #expect(unknown?["error"]?["code"] == .number(-32601))
        let missingTool = await server.handle(Self.request("tools/call", .object(["name": "rm"])))
        #expect(missingTool?["error"]?["code"] == .number(-32602))
    }
}

struct MCPHTTPEndpointTests {
    private let endpoint = MCPHTTPEndpoint(
        server: MCPServer(name: "RedOS", version: "1", instructions: "", tools: []), token: "secret", port: 47821
    )
    private let body = Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8)

    private func request(_ headers: [String: String], method: String = "POST", path: String = "/mcp") -> HTTPRequest {
        HTTPRequest(method: method, path: path, headers: headers, body: body)
    }

    @Test func requiresTheToken() async {
        let headers = ["host": "127.0.0.1:47821"]
        #expect(await endpoint.respond(request(headers)).status == 401)
        let wrong = headers.merging(["authorization": "Bearer nope"]) { $1 }
        #expect(await endpoint.respond(request(wrong)).status == 401)
        let right = headers.merging(["authorization": "Bearer secret"]) { $1 }
        let response = await endpoint.respond(request(right))
        #expect(response.status == 200)
        #expect(String(bytes: response.body, encoding: .utf8)?.contains(#""result":{}"#) == true)
    }

    @Test func refusesBrowsersAndOtherHosts() async {
        let valid = ["host": "127.0.0.1:47821", "authorization": "Bearer secret"]
        #expect(await endpoint.respond(request(valid.merging(["origin": "https://evil.example"]) { $1 })).status == 403)
        #expect(await endpoint.respond(request(valid.merging(["host": "evil.example:47821"]) { $1 })).status == 403)
        #expect(await endpoint.respond(request(valid, method: "GET")).status == 405)
        #expect(await endpoint.respond(request(valid, path: "/other")).status == 404)
    }

    @Test func servesOverHTTP() async throws {
        let port: UInt16 = 47_999
        let endpoint = MCPHTTPEndpoint(
            server: MCPServer(name: "RedOS", version: "1", instructions: "", tools: []), token: "secret", port: port
        )
        let server = try LocalHTTPServer(port: port) { await endpoint.respond($0) }
        server.start()
        defer { server.stop() }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        try await Task.sleep(for: .milliseconds(200))
        let (data, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(bytes: data, encoding: .utf8)?.contains(#""id":1"#) == true)
    }
}

struct MCPClientTests {
    /// A tiny stdio MCP server in Python with one read-only tool.
    private static let script = #"""
        import json, sys
        for line in sys.stdin:
            msg = json.loads(line)
            if "id" not in msg:
                continue
            method = msg["method"]
            if method == "initialize":
                result = {"protocolVersion": "2025-06-18", "capabilities": {"tools": {}},
                          "serverInfo": {"name": "test", "version": "1"}}
            elif method == "tools/list":
                result = {"tools": [{"name": "add", "description": "Adds two numbers.",
                    "inputSchema": {"type": "object", "properties": {
                        "a": {"type": "integer"}, "b": {"type": "number"}}, "required": ["a", "b"]},
                    "annotations": {"readOnlyHint": True}}]}
            elif method == "tools/call":
                args = msg["params"]["arguments"]
                result = {"content": [{"type": "text", "text": str(args["a"] + args["b"])}]}
            else:
                print(json.dumps({"jsonrpc": "2.0", "id": msg["id"],
                    "error": {"code": -32601, "message": "nope"}}), flush=True)
                continue
            print(json.dumps({"jsonrpc": "2.0", "id": msg["id"], "result": result}), flush=True)
        """#

    @Test func usesToolsOfAStdioServer() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "redos-mcp-test-\(UUID().uuidString).py")
        try Self.script.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let client = MCPStdioClient(config: MCPServerConfig(command: "python3", args: [url.path]))
        let tools = try await client.connect()
        #expect(tools.map(\.name) == ["add"])
        #expect(tools.first?.isReadOnly == true)

        let action = MCPToolAction(server: "test server", tool: try #require(tools.first), client: client)
        #expect(action.id == "mcp.test_server.add")
        #expect(action.risk == .safe)
        #expect(action.parameters.map(\.name) == ["a", "b"])
        #expect(action.parameters.first?.kind == .integer)
        #expect(try await action.report(["a": "2", "b": "3.5"]) == "5.5")
        await client.stop()
    }

    @Test func convertsArguments() {
        let schema: JSONValue = .object(["properties": .object([
            "n": .object(["type": "integer"]), "on": .object(["type": "boolean"]),
            "tags": .object(["type": "array"]), "name": .object(["type": "string"]),
        ])])
        let arguments = ["n": "4", "on": "sì", "tags": #"["a","b"]"#, "name": "x"]
        let converted = MCPToolAction.arguments(arguments, schema: schema)
        #expect(converted["n"] == .number(4))
        #expect(converted["on"] == .bool(true))
        #expect(converted["tags"] == .array(["a", "b"]))
        #expect(converted["name"] == .string("x"))
    }
}
