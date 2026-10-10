import AppKit
import Observation
import RedOSCore

/// Ollama on this Mac: installed, running, which models are there, downloads in progress.
/// Owned by the app so downloads go on when the Settings window is closed.
@MainActor
@Observable
final class OllamaSetup {
    /// Models Ollama has; nil while it is not reachable.
    private(set) var installed: [String]?
    private(set) var downloads: [String: Double] = [:]
    private(set) var isStarting = false
    private(set) var error: String?

    @ObservationIgnored private let client = OllamaClient(model: "")
    static let downloadURL = URL(string: "https://ollama.com/download")!
    private static let app = URL(filePath: "/Applications/Ollama.app")
    private static let commands = ["/opt/homebrew/bin/ollama", "/usr/local/bin/ollama"]
    private static let brew = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]

    var isRunning: Bool { installed != nil }

    var isInstalledOnMac: Bool {
        FileManager.default.fileExists(atPath: Self.app.path)
            || Self.commands.contains { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func refresh() async {
        installed = try? await client.listModels()
    }

    func has(_ model: String) -> Bool {
        guard let installed else { return false }
        return installed.contains(model) || installed.contains("\(model):latest")
    }

    /// Models in `wanted` that Ollama does not have yet (empty while Ollama is not running).
    func missing(_ wanted: [String]) -> [String] {
        guard isRunning else { return [] }
        var seen = Set<String>()
        return wanted.filter { !$0.isEmpty && !has($0) && seen.insert($0).inserted }
    }

    /// Opens Ollama.app, or starts the Homebrew service, then waits up to 15 s for the server.
    func start() async {
        isStarting = true
        defer { isStarting = false }
        error = nil
        if FileManager.default.fileExists(atPath: Self.app.path) {
            _ = try? await NSWorkspace.shared.openApplication(at: Self.app, configuration: .init())
        } else if let brew = Self.brew.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            let process = Process()
            process.executableURL = URL(filePath: brew)
            process.arguments = ["services", "start", "ollama"]
            try? process.run()
        }
        for _ in 0..<30 where !isRunning {
            try? await Task.sleep(for: .milliseconds(500))
            await refresh()
        }
        if !isRunning { error = String(localized: "Ollama did not start. Open it from Applications.") }
    }

    func download(_ models: [String]) async {
        for model in models where downloads[model] == nil {
            await download(model)
        }
    }

    private func download(_ model: String) async {
        downloads[model] = 0
        defer { downloads[model] = nil }
        error = nil
        let (updates, feed) = AsyncStream<Double>.makeStream()
        let client = client
        let pull = Task {
            defer { feed.finish() }
            try await client.pull(model) { feed.yield($0) }
        }
        for await fraction in updates {
            downloads[model] = fraction
        }
        do {
            try await pull.value
        } catch {
            self.error = error.localizedDescription
        }
        await refresh()
    }
}
