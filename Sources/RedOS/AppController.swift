import AppKit
import Observation
import RedOSActions
import RedOSCore

@MainActor
@Observable
final class AppController {
    let permissions = PermissionCenter()
    let registry = ActionRegistry(SystemActions.all)
    private(set) var systemOneDescription = ""
    private(set) var systemTwoDescription = ""
    @ObservationIgnored let commandPanel: CommandPanelController
    @ObservationIgnored private var hotKey: GlobalHotKey?

    init() {
        commandPanel = CommandPanelController(engine: CommandEngine(registry: registry, audit: FileAuditLog()))
        reload()
    }

    /// Rebuilds the command engine from the current settings.
    func reload(_ settings: AppSettings = AppSettings()) {
        let ollama = OllamaClient(model: settings.systemOneModel)
        let systemOne: any SystemOne
        // Optional Jev-compatible backend, e.g. `make localjev-run` on http://127.0.0.1:8080.
        if let jevURL = URL(string: settings.jevURL), jevURL.scheme != nil {
            systemOne = JevHTTPSystemOne(baseURL: jevURL)
            systemOneDescription = "Jev · \(jevURL.absoluteString)"
        } else {
            systemOne = OllamaSystemOne(client: ollama)
            systemOneDescription = "Ollama · \(ollama.model)"
        }
        let router = SystemOneRouter(
            registry: registry,
            systemOne: systemOne,
            extractor: ArgumentExtractor(client: ollama),
            warmUp: ollama,
            threshold: settings.threshold
        )
        let planner: (any Planning)?
        do {
            planner = ModelPlanner(client: try settings.systemTwo().client())
            systemTwoDescription = settings.systemTwo().displayName
        } catch {
            planner = nil
            systemTwoDescription = error.localizedDescription
        }
        commandPanel.update(
            engine: CommandEngine(registry: registry, router: router, planner: planner, audit: FileAuditLog())
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
