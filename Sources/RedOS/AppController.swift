import AppKit
import Carbon.HIToolbox
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

    init() {
        commandPanel = CommandPanelController(engine: CommandEngine(registry: registry, audit: FileAuditLog()))
        reload()
    }

    /// Rebuilds the command engine from the current settings.
    func reload(_ settings: AppSettings = AppSettings()) {
        let ollama = OllamaClient(model: settings.systemOneModel)
        let extraction = OllamaClient(model: settings.extractionModel)
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
            extractor: ArgumentExtractor(client: extraction),
            warmUp: [ollama, extraction],
            threshold: settings.threshold
        )
        // Multi-step plans stay on the local decision model (~1 s, cached prompt); the configured provider
        // answers questions and unclear commands.
        let planner = ModelPlanner(client: ollama)
        let assistant: (any Planning)?
        do {
            assistant = ModelPlanner(client: try settings.systemTwo().client())
            systemTwoDescription = settings.systemTwo().displayName
        } catch {
            assistant = nil
            systemTwoDescription = error.localizedDescription
        }
        let voice = VoiceSettings(
            locale: Locale(identifier: settings.voiceLocale), speaksAnswers: settings.speaksAnswers
        )
        commandPanel.update(
            engine: CommandEngine(
                registry: registry, router: router, planner: planner, assistant: assistant,
                agent: ModelAgent(client: ollama), observer: AccessibilityObserver(), audit: FileAuditLog()
            ),
            voice: voice
        )
    }

    func start() {
        let hotKeys = HotKeyCenter.shared
        hotKeys.register(keyCode: kVK_Space, modifiers: optionKey) { [weak self] in self?.commandPanel.toggle() }
        hotKeys.register(
            keyCode: kVK_Space, modifiers: controlKey | optionKey,
            onPress: { [weak self] in self?.commandPanel.startListening() },
            onRelease: { [weak self] in self?.commandPanel.stopListening() }
        )
        // Kill switch.
        hotKeys.register(keyCode: kVK_Escape, modifiers: controlKey | optionKey) { [weak self] in
            self?.commandPanel.stop()
        }
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
