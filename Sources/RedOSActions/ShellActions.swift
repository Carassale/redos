import Foundation
import RedOSCore

struct RunShellAction: ReportingAction {
    static let timeout: Duration = .seconds(60)
    static let maxOutput = 6000

    let id = "shell.run"
    let summary = "Run a shell command line the user states (e.g. git status, ls ~/Downloads) in zsh and show"
        + " its output."
    let risk = RiskLevel.dangerous
    let parameters = [ActionParameter("command", description: "The exact zsh command line")]

    @MainActor
    func report(_ arguments: ActionArguments) async throws -> String {
        let command = try arguments.string("command")
        let result = try await ShellProcess(command: command).run(timeout: Self.timeout)
        var output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if output.count > Self.maxOutput {
            output = String(output.prefix(Self.maxOutput)) + "\n…"
        }
        guard result.exitCode == 0 else {
            let code = Int(result.exitCode)
            throw ActionError.failed(String(localized: "Exit code \(code)") + (output.isEmpty ? "" : "\n\(output)"))
        }
        return output.isEmpty ? String(localized: "Done, no output.") : output
    }
}

/// A non-interactive login shell in the home folder; stopped on timeout or task cancellation.
private final class ShellProcess: @unchecked Sendable {
    private let process = Process()
    private let pipe = Pipe()
    private let lock = NSLock()
    private var timedOut = false

    init(command: String) {
        process.executableURL = URL(filePath: "/bin/zsh")
        process.arguments = ["-lc", command]
        process.currentDirectoryURL = URL.homeDirectory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = pipe
    }

    func run(timeout: Duration) async throws -> (output: String, exitCode: Int32) {
        try process.run()
        let timer = Task { [self] in
            try await Task.sleep(for: timeout)
            lock.withLock { timedOut = true }
            process.terminate()
        }
        defer { timer.cancel() }
        let data = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global().async { [self] in
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    continuation.resume(returning: data)
                }
            }
        } onCancel: { [self] in
            process.terminate()
        }
        try Task.checkCancellation()
        if lock.withLock({ timedOut }) {
            throw ActionError.failed(String(localized: "The command timed out."))
        }
        return (String(bytes: data, encoding: .utf8) ?? "", process.terminationStatus)
    }
}
