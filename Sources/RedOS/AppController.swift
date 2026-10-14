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
    let behaviors = BehaviorStore()
    /// Survives engine rebuilds (settings changes) so a follow-up still has its context.
    let conversation = Conversation()
    let notes = NoteTaker()
    @ObservationIgnored lazy var notesWindow = NotesWindowController(
        taker: notes,
        onStop: { [weak self] in Task { @MainActor in await self?.setTakingNotes(false) } },
        onCommand: { [weak self] text in self?.commandPanel.submit(typed: text) }
    )
    @ObservationIgnored lazy var proactive = ProactiveCenter(panel: commandPanel, notes: notes)
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
        commandPanel.onTakeNotes = { [weak self] start in await self?.setTakingNotes(start) }
        commandPanel.onBriefing = { [weak self] in await self?.proactive.briefing() ?? "" }
        commandPanel.describeSetup = { [weak self] in
            let system = ProcessInfo.processInfo.operatingSystemVersionString
            return "RedOS \(AppInfo.version) · macOS \(system) · System One: \(self?.systemOneDescription ?? "")"
                + " · System Two: \(self?.systemTwoDescription ?? "")"
        }
        systemOneDescription = String(localized: "Waiting for the Keychain…")
        systemTwoDescription = systemOneDescription
        Task { [weak self] in
            await Keychain.preload()
            self?.reload()
            self?.reloadMCPServers()
        }
    }

    /// Rebuilds the command engine, the wake word and the MCP server from the current settings.
    func reload(_ settings: AppSettings = AppSettings()) {
        self.settings = settings
        rebuildEngine(settings)
        configureWakeWord(settings)
        configureMCPServer(settings)
        configureProactivity(settings)
    }

    private func configureProactivity(_ settings: AppSettings) {
        proactive.isEnabled = settings.isProactive
        proactive.briefsInTheMorning = settings.isProactive && settings.morningBriefing
        proactive.policy = InterruptionPolicy(jev: settings.offlineOnly ? nil : jevClient(settings))
        let language = Locale(identifier: settings.voiceLocale).language.languageCode?.identifier ?? "en"
        proactive.language = Locale(identifier: "en").localizedString(forLanguageCode: language) ?? language
    }

    func rebuildEngine(_ settings: AppSettings) {
        let ollama = OllamaClient(model: settings.systemOneModel)
        let extraction = OllamaClient(model: settings.extractionModel)
        let router = makeRouter(settings, ollama: ollama, extraction: extraction)
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
            locale: Locale(identifier: settings.voiceLocale), speaksAnswers: settings.speaksAnswers,
            keepsListening: settings.keepsListening
        )
        let web = WebTools(locale: settings.voiceLocale)
        notes.client = writer
        notes.locale = voice.locale
        let designer = diagramDesigner(settings, writer: writer, local: ollama)
        commandPanel.update(
            engine: CommandEngine(
                registry: ActionRegistry(SystemActions.all + mcpActions), router: router,
                planner: ModelPlanner(client: thinker),
                assistant: ModelPlanner(client: writer),
                agent: screenAgent(settings, thinker: thinker),
                observer: AccessibilityObserver(seesScreen: settings.seesScreen),
                routines: routines, memory: memory, conversation: conversation, writer: writer,
                web: web, researcher: ResearchAgent(client: writer, tools: web), designer: designer,
                corrector: correctionClassifier(settings, local: ollama),
                behaviors: behaviors, persona: settings.persona.instructions(custom: settings.customPersona),
                meetings: notes.store,
                audit: FileAuditLog()
            ),
            voice: voice
        )
    }

    /// Jev understands corrections best; the local model answers when Jev is off or unreachable.
    private func correctionClassifier(_ settings: AppSettings, local: OllamaClient) -> CorrectionClassifier {
        var deciders: [any SystemOne] = []
        if !settings.offlineOnly, let jev = jevClient(settings) { deciders.append(jev) }
        deciders.append(OllamaSystemOne(client: local))
        return CorrectionClassifier(deciders: deciders)
    }

    /// With Jev, clicks and scrolls are Jev choices (fast); typing, apps and unsure steps stay with System Two.
    private func screenAgent(_ settings: AppSettings, thinker: any ChatCompleting) -> any Acting {
        let model = ModelAgent(client: thinker)
        guard !settings.offlineOnly, let jev = jevClient(settings) else { return model }
        return JevAgent(jev: jev, fallback: model)
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

    /// The local model picks single actions; Jev (Codiv or a custom server) recognizes every other kind of
    /// request at the same time. Offline, unreachable or not configured, the local model works alone.
    private func makeRouter(
        _ settings: AppSettings, ollama: OllamaClient, extraction: OllamaClient
    ) -> any CommandRouting {
        // Accuracy: unsure single actions go to System Two instead of running.
        let threshold = settings.prefersAccuracy ? max(settings.threshold, 0.85) : settings.threshold
        let extractor = ArgumentExtractor(client: extraction)
        let local = SystemOneRouter(
            registry: registry, systemOne: OllamaSystemOne(client: ollama), extractor: extractor,
            warmUp: [ollama, extraction], threshold: threshold
        )
        systemOneDescription = "Ollama · \(ollama.model)"
        guard !settings.offlineOnly, let jev = jevClient(settings) else { return local }
        systemOneDescription = "Jev · \(jev.model) · \(jev.baseURL.host() ?? "")"
        let remote = JevIntentRouter(
            registry: ActionRegistry(SystemActions.all + mcpActions), jev: jev, extractor: extractor,
            warmUp: [extraction], threshold: threshold
        )
        return HybridRouter(local: local, remote: remote)
    }

    func jevClient(_ settings: AppSettings) -> JevHTTPSystemOne? {
        let key = Keychain.secret(for: DecisionProvider.keyAccount)
        switch settings.decisionProvider {
        case .local:
            return nil
        case .codiv:
            guard let key, !key.isEmpty else { return nil }
            return JevHTTPSystemOne(baseURL: JevHTTPSystemOne.codivURL, model: settings.jevModel, apiKey: key)
        case .custom:
            guard let url = URL(string: settings.jevURL), url.scheme != nil else { return nil }
            return JevHTTPSystemOne(baseURL: url, model: settings.jevModel, apiKey: key)
        }
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
        proactive.start()
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
