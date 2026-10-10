import AppKit
import Carbon.HIToolbox
import Observation
import RedOSActions
import RedOSCore
import RedOSWakeWord

@MainActor
@Observable
final class AppController {
    let permissions = PermissionCenter()
    let updater = Updater()
    let routines = RoutineStore()
    let memory = MemoryStore()
    let usage = UsageStore()
    let ollama = OllamaSetup()
    @ObservationIgnored private lazy var triggers = TriggerCenter(routines: routines) { [weak self] routine in
        self?.commandPanel.runRoutine(named: routine.name)
    }
    let registry = ActionRegistry(SystemActions.all)
    private(set) var systemOneDescription = ""
    private(set) var systemTwoDescription = ""
    private(set) var hasUnseenResult = false
    /// Why the wake word is not listening although enabled.
    private(set) var wakeWordError: String?
    let mcpHub = MCPHub()
    var mcpStatuses: [MCPHub.Status] = []
    var mcpServerError: String?
    @ObservationIgnored var mcpServer: LocalHTTPServer?
    /// The running server's settings, so it restarts only when they change.
    @ObservationIgnored var mcpServerKey = ""
    /// Tools of external MCP servers, offered to System Two next to the built-in actions.
    @ObservationIgnored var mcpActions: [any Action] = []
    @ObservationIgnored var settings = AppSettings()
    @ObservationIgnored let commandPanel: CommandPanelController

    init() {
        commandPanel = CommandPanelController(engine: CommandEngine(registry: registry, audit: FileAuditLog()))
        commandPanel.onUnseenResultChange = { [weak self] in self?.hasUnseenResult = $0 }
        reload()
        reloadMCPServers()
    }

    /// Rebuilds the command engine, the wake word and the MCP server from the current settings.
    func reload(_ settings: AppSettings = AppSettings()) {
        self.settings = settings
        rebuildEngine(settings)
        configureWakeWord(settings)
        configureMCPServer(settings)
    }

    func rebuildEngine(_ settings: AppSettings) {
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
            // Accuracy: unsure single actions go to System Two instead of running.
            threshold: settings.prefersAccuracy ? max(settings.threshold, 0.85) : settings.threshold
        )
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
        // Accuracy: multi-step plans and the screen agent use the provider too; speed keeps them on the
        // local model (~1 s, cached prompt).
        let thinker: any ChatCompleting = settings.prefersAccuracy ? writer : ollama
        Task { await writer.preload() }
        let voice = VoiceSettings(
            locale: Locale(identifier: settings.voiceLocale), speaksAnswers: settings.speaksAnswers
        )
        let web = WebTools(locale: settings.voiceLocale)
        let designer = diagramDesigner(settings, writer: writer, local: ollama)
        commandPanel.update(
            engine: CommandEngine(
                registry: ActionRegistry(SystemActions.all + mcpActions), router: router,
                planner: ModelPlanner(client: thinker),
                assistant: ModelPlanner(client: writer),
                agent: ModelAgent(client: thinker), observer: AccessibilityObserver(),
                routines: routines, memory: memory, writer: writer,
                web: web, researcher: ResearchAgent(client: writer, tools: web), designer: designer,
                audit: FileAuditLog()
            ),
            voice: voice
        )
    }

    private func diagramDesigner(
        _ settings: AppSettings, writer: any ChatCompleting, local: OllamaClient
    ) -> DiagramDesigner? {
        // Speed: diagrams think less (about 15% faster with Copilot); accuracy keeps the default effort.
        let drawer = settings.prefersAccuracy
            ? writer
            : (try? systemTwoClient(settings, local: local, reasoningEffort: "low")) ?? writer
        return Bundle.main.resourceURL
            .flatMap { DiagramLibrary(directory: $0.appending(path: "DiagramDesign")) }
            .map { DiagramDesigner(client: drawer, library: $0) }
    }

    private func configureWakeWord(_ settings: AppSettings) {
        wakeWordError = nil
        guard settings.wakeWordEnabled else {
            commandPanel.wakeWord?.stop()
            commandPanel.wakeWord = nil
            return
        }
        if let wakeWord = commandPanel.wakeWord {
            wakeWord.threshold = Float(settings.wakeWordThreshold)
            return
        }
        guard SystemPermissionChecker().status(of: .microphone) == .granted else {
            wakeWordError = ActionError.permissionMissing(.microphone).localizedDescription
            return
        }
        do {
            guard let models = Bundle.main.resourceURL?.appending(path: "WakeWord") else {
                throw WakeWordError.modelNotFound
            }
            let wakeWord = try WakeWordListener(
                model: models.appending(path: "hey_red.onnx"), featureModels: models,
                threshold: Float(settings.wakeWordThreshold)
            )
            wakeWord.onDetect = { [weak self] in self?.commandPanel.startListening(handsFree: true) }
            try wakeWord.start()
            commandPanel.wakeWord = wakeWord
        } catch {
            wakeWordError = error.localizedDescription
        }
    }

    /// Cloud providers are metered and fall back to the local model past the daily limit or when offline.
    private func systemTwoClient(
        _ settings: AppSettings, local: OllamaClient, reasoningEffort: String? = nil
    ) throws -> any ChatCompleting {
        if settings.offlineOnly { return local }
        let client = try settings.systemTwo().client(reasoningEffort: reasoningEffort)
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
