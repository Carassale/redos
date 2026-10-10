import Foundation

/// GitHub Copilot through a long-lived `copilot --acp` process (Agent Client Protocol over stdio): about 1 s per
/// call instead of ~5 s for starting the CLI each time. Tools and MCP servers are disabled; every call opens a
/// fresh session so requests never share context.
public struct CopilotACPClient: ChatCompleting, ModelListing {
    private let connection: ACPConnection
    private let executable: URL
    private let timeout: Duration

    /// `reasoningEffort` (low, medium, high…) trades thinking time for speed; nil keeps Copilot's default.
    public init(executable: URL, model: String?, reasoningEffort: String? = nil, timeout: Duration = .seconds(300)) {
        self.executable = executable
        self.timeout = timeout
        connection = ACPConnection(executable: executable, model: model, reasoningEffort: reasoningEffort)
    }

    public func chat(
        _ messages: [ChatMessage], format: JSONValue?, maxTokens: Int?, topLogprobs: Int?
    ) async throws -> ChatResponse {
        var prompt = messages.map { "\($0.role.uppercased()):\n\($0.content)" }.joined(separator: "\n\n")
        if format != nil {
            prompt += "\n\nReply with a single JSON object only."
        }
        let text = try await connection.prompt(prompt, timeout: timeout, progress: ActivityReporter.handler)
        guard !text.isEmpty else { throw ProviderError.emptyResponse }
        return ChatResponse(message: .init(content: text), logprobs: nil)
    }

    /// Starts the process ahead of the first request.
    public func preload() async {
        try? await connection.start()
    }

    public func listModels() async throws -> [String] {
        try await CopilotCLIClient(executable: executable, model: nil).listModels()
    }
}

/// One `copilot --acp` process; JSON-RPC requests are matched to responses by id.
actor ACPConnection {
    private let executable: URL
    private let model: String?
    private let reasoningEffort: String?
    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<JSONValue, any Error>] = [:]
    /// Message text received so far, by session id.
    private var replies: [String: String] = [:]
    /// Who wants to see a long reply arriving, by session id.
    private var watchers: [String: ActivityHandler] = [:]
    private let workDirectory = FileManager.default.temporaryDirectory.appending(path: "redos-copilot")

    init(executable: URL, model: String?, reasoningEffort: String?) {
        self.executable = executable
        self.model = model
        self.reasoningEffort = reasoningEffort
    }

    deinit {
        process?.terminate()
    }

    func start() async throws {
        guard process == nil else { return }
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = executable
        // "none" is not a tool, so the model gets no tools at all (an empty list is ignored and the model
        // would try to write files); it also drops ~15k tokens of tool descriptions from every call.
        var arguments = ["--acp", "--available-tools=none", "--disable-builtin-mcps", "--no-custom-instructions"]
        if let model, !model.isEmpty { arguments += ["--model", model] }
        if let reasoningEffort { arguments += ["--reasoning-effort", reasoningEffort] }
        process.arguments = arguments
        // An empty working directory: no repository instructions or files are in reach.
        process.currentDirectoryURL = workDirectory
        var environment = ProcessInfo.processInfo.environment
        // `copilot` is a Node script: its own directory usually holds `node` too.
        environment["PATH"] = ([executable.deletingLastPathComponent().path] + [
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
        ]).joined(separator: ":")
        process.environment = environment
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        // One consumer keeps the chunks in order (a Task per chunk could reorder them).
        let (chunks, feed) = AsyncStream<Data>.makeStream()
        stdout.fileHandleForReading.readabilityHandler = { handle in
            feed.yield(handle.availableData)
        }
        Task { [weak self] in
            for await data in chunks {
                await self?.receive(data)
            }
        }
        process.terminationHandler = { [weak self] _ in
            feed.finish()
            Task { await self?.stopped() }
        }
        do {
            try process.run()
        } catch {
            throw ProviderError.commandFailed(error.localizedDescription)
        }
        self.process = process
        input = stdin.fileHandleForWriting
        _ = try await request("initialize", ["protocolVersion": .number(1), "clientCapabilities": .object([:])])
    }

    func prompt(_ text: String, timeout: Duration, progress: ActivityHandler? = nil) async throws -> String {
        try await start()
        let session = try await request(
            "session/new", ["cwd": .string(workDirectory.path), "mcpServers": .array([])]
        )
        guard case .string(let sessionID) = session["sessionId"] else { throw ProviderError.emptyResponse }
        replies[sessionID] = ""
        watchers[sessionID] = progress
        defer {
            replies[sessionID] = nil
            watchers[sessionID] = nil
        }
        let watchdog = Task { [weak self] in
            try await Task.sleep(for: timeout)
            await self?.cancel(sessionID)
        }
        defer { watchdog.cancel() }
        let result = try await withTaskCancellationHandler {
            try await request(
                "session/prompt",
                ["sessionId": .string(sessionID), "prompt": .array([.object(["type": "text", "text": .string(text)])])]
            )
        } onCancel: {
            Task { await self.cancel(sessionID) }
        }
        if result["stopReason"]?.string == "cancelled" {
            throw Task.isCancelled ? CancellationError() : ProviderError.commandFailed("Copilot timed out")
        }
        let reply = (replies[sessionID] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return reply
    }

    private func request(_ method: String, _ params: [String: JSONValue]) async throws -> JSONValue {
        nextID += 1
        let id = nextID
        let message: JSONValue = .object([
            "jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method), "params": .object(params),
        ])
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do {
                try send(message)
            } catch {
                pending[id] = nil
                continuation.resume(throwing: error)
            }
        }
    }

    private func send(_ message: JSONValue) throws {
        guard let input else { throw ProviderError.commandFailed("Copilot is not running") }
        var data = try JSONEncoder().encode(message)
        data.append(0x0A)
        try input.write(contentsOf: data)
    }

    private func cancel(_ sessionID: String) {
        try? send(.object([
            "jsonrpc": "2.0", "method": "session/cancel", "params": .object(["sessionId": .string(sessionID)]),
        ]))
    }

    private func receive(_ data: Data) {
        guard !data.isEmpty else { return }
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
                continuation.resume(throwing: ProviderError.commandFailed(error["message"]?.string ?? "ACP error"))
            } else {
                continuation.resume(returning: message["result"] ?? .null)
            }
        } else if method == "session/update", let params = message["params"],
                  let session = params["sessionId"]?.string,
                  params["update"]?["sessionUpdate"]?.string == "agent_message_chunk",
                  let chunk = params["update"]?["content"]?["text"]?.string {
            let before = replies[session]?.count ?? 0
            // Copilot's own notices ("Info: Disabled tools: …") arrive as whole chunks before the reply.
            if before == 0, chunk.hasPrefix("Info: ") { return }
            replies[session, default: ""] += chunk
            // Only long replies (diagrams) report progress, every ~1000 characters.
            let after = before + chunk.count
            if after >= 1000, after / 1000 != before / 1000, let watcher = watchers[session] {
                Task { await watcher(.receiving(characters: after)) }
            }
        } else if let id = message["id"], method != nil {
            // Requests from Copilot (permissions, files): tools are off, so decline.
            try? send(.object([
                "jsonrpc": "2.0", "id": id,
                "error": .object(["code": .number(-32601), "message": "not supported"]),
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
            continuation.resume(throwing: ProviderError.commandFailed("Copilot stopped"))
        }
    }
}

extension JSONValue {
    public subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    public var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }
}

extension JSONValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self = .string(value)
    }
}
