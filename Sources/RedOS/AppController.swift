import AppKit
import Carbon.HIToolbox
import Observation
import RedOSActions
import RedOSCore

@MainActor
@Observable
final class AppController {
    let permissions = PermissionCenter()
    let updater = Updater()
    let routines = RoutineStore()
    let memory = MemoryStore()
    let usage = UsageStore()
    @ObservationIgnored private lazy var triggers = TriggerCenter(routines: routines) { [weak self] routine in
        self?.commandPanel.runRoutine(named: routine.name)
    }
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
        let writer: any ChatCompleting
        do {
            writer = try systemTwoClient(settings, local: ollama)
            systemTwoDescription = settings.offlineOnly
                ? String(localized: "Offline · \(ollama.model)")
                : settings.systemTwo().displayName
        } catch {
            writer = ollama
            systemTwoDescription = error.localizedDescription
        }
        let voice = VoiceSettings(
            locale: Locale(identifier: settings.voiceLocale), speaksAnswers: settings.speaksAnswers
        )
        let web = WebTools(locale: settings.voiceLocale)
        let designer = Bundle.main.resourceURL
            .flatMap { DiagramLibrary(directory: $0.appending(path: "DiagramDesign")) }
            .map { DiagramDesigner(client: writer, library: $0) }
        commandPanel.update(
            engine: CommandEngine(
                registry: registry, router: router, planner: planner, assistant: ModelPlanner(client: writer),
                agent: ModelAgent(client: ollama), observer: AccessibilityObserver(),
                routines: routines, memory: memory, writer: writer,
                web: web, researcher: ResearchAgent(client: writer, tools: web), designer: designer,
                audit: FileAuditLog()
            ),
            voice: voice
        )
    }

    /// Cloud providers are metered and fall back to the local model past the daily limit or when offline.
    private func systemTwoClient(_ settings: AppSettings, local: OllamaClient) throws -> any ChatCompleting {
        if settings.offlineOnly { return local }
        let client = try settings.systemTwo().client()
        guard settings.systemTwoProvider != .ollama else { return client }
        return MeteredClient(inner: client, fallback: local, store: usage, dailyLimit: settings.dailyCloudLimit)
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
        triggers.start()
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
