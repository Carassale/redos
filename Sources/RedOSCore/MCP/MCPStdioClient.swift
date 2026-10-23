import Foundation

/// One MCP server RedOS uses, in the `mcpServers` format of Claude Desktop and VS Code:
/// started locally (`command`) or reached over Streamable HTTP (`url`).
public struct MCPServerConfig: Codable, Sendable, Equatable {
    public var command: String?
    public var args: [String]?
    public var env: [String: String]?
    public var type: String?
    public var url: String?
    public var headers: [String: String]?
    public var disabled: Bool?
    /// Its tools run without asking for confirmation.
    public var trusted: Bool?
    /// Tools that take long (e.g. an assistant writing its own answer): RedOS calls them only when System Two
    /// picks them, never on a quick guess.
    public var slowTools: [String]?

    public init(
        command: String? = nil, args: [String]? = nil, env: [String: String]? = nil,
        url: String? = nil, headers: [String: String]? = nil, disabled: Bool? = nil, trusted: Bool? = nil
    ) {
        self.command = command
        self.args = args
        self.env = env
        self.type = url == nil ? nil : "http"
        self.url = url
        self.headers = headers
        self.disabled = disabled
        self.trusted = trusted
    }

    public func makeClient() throws -> any MCPClient {
        if let url {
            guard let address = URL(string: url), ["http", "https"].contains(address.scheme) else {
                throw ProviderError.commandFailed("Invalid MCP server URL: \(url)")
            }
            return MCPHTTPClient(url: address, headers: headers ?? [:])
        }
        guard let command, !command.isEmpty else {
            throw ProviderError.commandFailed("MCP server without command or url")
        }
        return MCPStdioClient(command: command, args: args ?? [], env: env ?? [:])
    }
}

public struct MCPConfiguration: Codable, Sendable, Equatable {
    public var mcpServers: [String: MCPServerConfig]

    public init(mcpServers: [String: MCPServerConfig] = [:]) {
        self.mcpServers = mcpServers
    }

    public static let defaultURL = URL.applicationSupportDirectory.appending(path: "RedOS/mcp.json")

    public static func load(from url: URL = defaultURL) -> MCPConfiguration {
        guard let data = try? Data(contentsOf: url) else { return MCPConfiguration() }
        return (try? JSONDecoder().decode(MCPConfiguration.self, from: data)) ?? MCPConfiguration()
    }

    public func save(to url: URL = defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

public struct MCPToolInfo: Sendable, Equatable {
    public let name: String
    public let description: String
    public let inputSchema: JSONValue
    public let isReadOnly: Bool
    /// MCP's default when a server does not say: the tool may change things.
    public let isDestructive: Bool
}

/// A connection to an MCP server; the transport (stdio, HTTP) only has to carry JSON-RPC messages.
public protocol MCPClient: Actor {
    func request(_ method: String, _ params: [String: JSONValue]) async throws -> JSONValue
    func notify(_ method: String) async throws
    func stop()
}

extension MCPClient {
    /// Opens the session and returns the server's tools.
    public func connect() async throws -> [MCPToolInfo] {
        _ = try await request("initialize", [
            "protocolVersion": .string(MCPServer.protocolVersion),
            "capabilities": .object([:]),
            "clientInfo": .object(["name": "RedOS", "version": "1"]),
        ])
        try await notify("notifications/initialized")
        var tools: [MCPToolInfo] = []
        var cursor: JSONValue?
        repeat {
            let page = try await request("tools/list", cursor.map { ["cursor": $0] } ?? [:])
            if case .array(let items) = page["tools"] { tools += items.compactMap(Self.tool) }
            cursor = page["nextCursor"]
        } while cursor?.string != nil
        return tools
    }

    public func call(_ tool: String, arguments: [String: JSONValue]) async throws -> MCPToolResult {
        let result = try await request("tools/call", ["name": .string(tool), "arguments": .object(arguments)])
        var texts: [String] = []
        if case .array(let content) = result["content"] {
            for item in content {
                if let text = item["text"]?.string {
                    texts.append(text)
                } else if let type = item["type"]?.string {
                    texts.append("[\(type)]")
                }
            }
        }
        return MCPToolResult(texts.joined(separator: "\n"), isError: result["isError"] == .bool(true))
    }

    private static func tool(_ value: JSONValue) -> MCPToolInfo? {
        guard let name = value["name"]?.string else { return nil }
        let annotations = value["annotations"]
        let readOnly = annotations?["readOnlyHint"] == .bool(true)
        return MCPToolInfo(
            name: name,
            description: value["description"]?.string ?? "",
            inputSchema: value["inputSchema"] ?? .object([:]),
            isReadOnly: readOnly,
            isDestructive: !readOnly && annotations?["destructiveHint"] != .bool(false)
        )
    }
}

/// An MCP server started as a child process, speaking JSON-RPC over stdio (one JSON message per line).
public actor MCPStdioClient: MCPClient {
    private let command: String
    private let args: [String]
    private let env: [String: String]
    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<JSONValue, any Error>] = [:]

    public init(command: String, args: [String] = [], env: [String: String] = [:]) {
        self.command = command
        self.args = args
        self.env = env
    }

    deinit {
        process?.terminate()
    }

    public func stop() {
        process?.terminate()
        process = nil
    }

    public func notify(_ method: String) throws {
        try send(.object(["jsonrpc": "2.0", "method": .string(method)]))
    }

    private func start() async throws {
        guard process == nil else { return }
        let process = Process()
        let path = await Self.loginPath()
        // `npx`, `uvx`, `node`… are found through the user's PATH, like in Terminal.
        process.executableURL = URL(filePath: "/usr/bin/env")
        process.arguments = [command] + args
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = path
        environment.merge(env) { _, new in new }
        process.environment = environment
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        let (chunks, feed) = AsyncStream<Data>.makeStream()
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                feed.finish()
            } else {
                feed.yield(data)
            }
        }
        Task { [weak self] in
            for await data in chunks {
                await self?.receive(data)
            }
            await self?.stopped()
        }
        do {
            try process.run()
        } catch {
            throw ProviderError.commandFailed(error.localizedDescription)
        }
        self.process = process
        input = stdin.fileHandleForWriting
    }

    private static let pathCache = PathCache()

    /// The login shell's PATH (GUI apps get a minimal one), with common install locations as fallback.
    static func loginPath() async -> String {
        if let cached = await pathCache.value { return cached }
        let fallback = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        // Started from Terminal the PATH is already complete (launchd gives GUI apps only the 4 system folders).
        let inherited = ProcessInfo.processInfo.environment["PATH"] ?? ""
        if inherited.split(separator: ":").count > 4 { return inherited + ":" + fallback }
        // Written to a file: prompt helpers started by .zshrc can keep stdout open long after the shell exits.
        let file = FileManager.default.temporaryDirectory.appending(path: "redos-path-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        let shell = Process()
        shell.executableURL = URL(filePath: "/bin/zsh")
        shell.arguments = ["-ilc", "printf '%s' \"$PATH\" > '\(file.path)'"]
        shell.standardInput = FileHandle.nullDevice
        shell.standardOutput = FileHandle.nullDevice
        shell.standardError = FileHandle.nullDevice
        let exited = AsyncStream<Void> { continuation in
            shell.terminationHandler = { _ in continuation.finish() }
        }
        if (try? shell.run()) != nil {
            let watchdog = Task {
                try await Task.sleep(for: .seconds(10))
                shell.terminate()
            }
            for await _ in exited {}
            watchdog.cancel()
        }
        let shellPath = (try? String(contentsOf: file, encoding: .utf8)).flatMap { $0.isEmpty ? nil : $0 }
        let path = [shellPath, fallback].compactMap(\.self).joined(separator: ":")
        await pathCache.set(path)
        return path
    }

    public func request(_ method: String, _ params: [String: JSONValue]) async throws -> JSONValue {
        if method == "initialize" { try await start() }
        let timeout: Duration = .seconds(120)
        nextID += 1
        let id = nextID
        let watchdog = Task { [weak self] in
            try await Task.sleep(for: timeout)
            await self?.fail(id, ProviderError.commandFailed("MCP request timed out: \(method)"))
        }
        defer { watchdog.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do {
                try send(.object([
                    "jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method), "params": .object(params),
                ]))
            } catch {
                pending[id] = nil
                continuation.resume(throwing: error)
            }
        }
    }

    private func fail(_ id: Int, _ error: any Error) {
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func send(_ message: JSONValue) throws {
        guard let input else { throw ProviderError.commandFailed("MCP server is not running") }
        var data = try JSONEncoder().encode(message)
        data.append(0x0A)
        try input.write(contentsOf: data)
    }

    private func receive(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard let message = try? JSONDecoder().decode(JSONValue.self, from: Data(line)) else { continue }
            handle(message)
        }
    }

    private func handle(_ message: JSONValue) {
        let method = message["method"]?.string
        if case .number(let number) = message["id"], method == nil {
            guard let continuation = pending.removeValue(forKey: Int(number)) else { return }
            if let error = message["error"] {
                continuation.resume(throwing: ProviderError.commandFailed(error["message"]?.string ?? "MCP error"))
            } else {
                continuation.resume(returning: message["result"] ?? .null)
            }
        } else if let id = message["id"], method != nil {
            // Requests from the server (sampling, roots…) are not supported.
            try? send(.object([
                "jsonrpc": "2.0", "id": id, "error": .object(["code": .number(-32601), "message": "not supported"]),
            ]))
        }
    }

    private func stopped() {
        process = nil
        input = nil
        buffer.removeAll()
        let waiting = pending
        pending.removeAll()
        for continuation in waiting.values {
            continuation.resume(throwing: ProviderError.commandFailed("MCP server stopped"))
        }
    }
}

private actor PathCache {
    var value: String?

    func set(_ path: String) {
        value = path
    }
}
