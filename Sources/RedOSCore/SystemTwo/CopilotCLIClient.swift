import Foundation

/// GitHub Copilot through the official Copilot CLI in prompt mode, with every tool and MCP server disabled
/// so it can only answer with text.
public struct CopilotCLIClient: ChatCompleting, ModelListing {
    public let executable: URL
    /// nil lets Copilot pick ("auto").
    public let model: String?
    private let timeout: Duration

    public init(executable: URL, model: String?, timeout: Duration = .seconds(90)) {
        self.executable = executable
        self.model = model
        self.timeout = timeout
    }

    public func chat(
        _ messages: [ChatMessage], format: JSONValue?, maxTokens: Int?, topLogprobs: Int?
    ) async throws -> ChatResponse {
        var prompt = messages.map { "\($0.role.uppercased()):\n\($0.content)" }.joined(separator: "\n\n")
        if format != nil {
            prompt += "\n\nReply with a single JSON object only."
        }
        var arguments = ["-p", prompt, "-s", "--available-tools=", "--disable-builtin-mcps", "--no-color"]
        if let model, !model.isEmpty {
            arguments += ["--model", model]
        }
        let output = try await Self.run(executable, arguments, timeout: timeout)
        guard !output.isEmpty else { throw ProviderError.emptyResponse }
        return ChatResponse(message: .init(content: output), logprobs: nil)
    }

    public func preload() async {}

    /// Model ids documented by `copilot help config`.
    public func listModels() async throws -> [String] {
        let help = try await Self.run(executable, ["help", "config"], timeout: .seconds(20))
        var models: [String] = []
        var inModelSection = false
        for line in help.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("  `model`:") {
                inModelSection = true
            } else if inModelSection, line.hasPrefix("    - \"") {
                models.append(line.trimmingCharacters(in: CharacterSet(charactersIn: " -\"")))
            } else if inModelSection, line.hasPrefix("  `") {
                break
            }
        }
        return models
    }

    /// Finds `copilot` in the user's login shell PATH (GUI apps do not inherit it, e.g. nvm installs).
    public static func locate() async -> URL? {
        let candidates = ["/opt/homebrew/bin/copilot", "/usr/local/bin/copilot"]
        if let path = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) {
            return URL(filePath: path)
        }
        let output = try? await run(
            URL(filePath: "/bin/zsh"), ["-ilc", "command -v copilot"], timeout: .seconds(10), checkStatus: false
        )
        let path = output?.split(separator: "\n").last { $0.hasPrefix("/") }.map(String.init)
        return path.flatMap { FileManager.default.isExecutableFile(atPath: $0) ? URL(filePath: $0) : nil }
    }

    /// Process is not Sendable; it is only touched to terminate it on timeout.
    private final class ProcessBox: @unchecked Sendable {
        let process = Process()
        private let lock = NSLock()
        private var expired = false

        var timedOut: Bool {
            get { lock.withLock { expired } }
            set { lock.withLock { expired = newValue } }
        }
    }

    private static func readToEnd(_ handle: FileHandle) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: handle.readDataToEndOfFile()) }
        }
    }

    static func run(
        _ executable: URL, _ arguments: [String], timeout: Duration, checkStatus: Bool = true
    ) async throws -> String {
        let box = ProcessBox()
        let process = box.process
        process.executableURL = executable
        process.arguments = arguments
        // An empty working directory: no repository instructions or files are in reach.
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        var environment = ProcessInfo.processInfo.environment
        // `copilot` is a Node script: its own directory usually holds `node` too.
        environment["PATH"] = ([executable.deletingLastPathComponent().path] + [
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
        ]).joined(separator: ":")
        process.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw ProviderError.commandFailed(error.localizedDescription)
        }
        // Dispatch, not Task: blocking pipe reads must not starve the watchdog on busy machines (CI).
        let watchdog = DispatchWorkItem {
            box.timedOut = true
            box.process.terminate()
        }
        let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: watchdog)
        defer { watchdog.cancel() }

        let outputHandle = stdout.fileHandleForReading
        let errorHandle = stderr.fileHandleForReading
        async let output = Self.readToEnd(outputHandle)
        async let errors = Self.readToEnd(errorHandle)
        let (outputData, errorData) = await (output, errors)
        process.waitUntilExit()

        if box.timedOut {
            throw ProviderError.commandFailed(String(localized: "The command timed out."))
        }
        if checkStatus, process.terminationStatus != 0 {
            let detail = String(bytes: errorData.prefix(300), encoding: .utf8) ?? ""
            throw ProviderError.commandFailed(detail.isEmpty ? "exit \(process.terminationStatus)" : detail)
        }
        return (String(bytes: outputData, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
