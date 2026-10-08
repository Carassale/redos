import AppKit
import RedOSActions
import RedOSCore

@MainActor
final class AppController {
    let permissions = PermissionCenter()
    let systemOneDescription: String
    let commandPanel: CommandPanelController
    private var hotKey: GlobalHotKey?

    init(defaults: UserDefaults = .standard) {
        let registry = ActionRegistry(SystemActions.all)
        let ollama = OllamaClient(model: defaults.string(forKey: "systemOne.model") ?? "gemma4:e4b-it-qat")
        let systemOne: any SystemOne
        // Optional Jev-compatible backend, e.g. `make localjev-run` on http://127.0.0.1:8080.
        if let jevURL = defaults.string(forKey: "systemOne.jevURL").flatMap(URL.init(string:)) {
            systemOne = JevHTTPSystemOne(baseURL: jevURL)
            systemOneDescription = "Jev · \(jevURL.absoluteString)"
        } else {
            systemOne = OllamaSystemOne(client: ollama)
            systemOneDescription = "Ollama · \(ollama.model)"
        }
        let threshold = defaults.object(forKey: "systemOne.threshold") as? Double ?? 0.6
        let router = SystemOneRouter(
            registry: registry,
            systemOne: systemOne,
            extractor: ArgumentExtractor(client: ollama),
            warmUp: ollama,
            threshold: threshold
        )
        commandPanel = CommandPanelController(
            engine: CommandEngine(registry: registry, router: router, audit: FileAuditLog())
        )
    }

    func start() {
        hotKey = GlobalHotKey { [weak self] in self?.commandPanel.toggle() }
    }

    func revealAuditLog() {
        let url = FileAuditLog.defaultURL
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent().deletingLastPathComponent())
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = AppController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.start()
    }
}
