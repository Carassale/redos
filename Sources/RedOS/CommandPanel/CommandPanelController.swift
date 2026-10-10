import AppKit
import RedOSCore
import RedOSVoice
import RedOSWakeWord

struct VoiceSettings: Equatable {
    var locale: Locale
    var speaksAnswers: Bool
    /// After a spoken request, the microphone stays open for a follow-up (and to talk over the answer).
    var keepsListening: Bool
}

@MainActor
final class CommandPanelController {
    private static let historyKey = "commandHistory"

    private(set) var engine: CommandEngine
    private(set) var voice = VoiceSettings(
        locale: Locale(identifier: "en_US"), speaksAnswers: true, keepsListening: true
    )
    private let defaults: UserDefaults
    let model = CommandPanelModel()
    let listener = SpeechListener()
    let speaker = Speaker()
    /// The wake word is not listened for while a command is being dictated.
    var listening: Task<Void, Never>? {
        didSet {
            guard (listening == nil) != (oldValue == nil) else { return }
            if listening == nil { try? wakeWord?.start() } else { wakeWord?.stop() }
        }
    }
    var wakeWord: WakeWordListener?
    let endpoint = DictationEndpoint()
    /// The command being resolved or run: the kill switch cancels it.
    private var work: Task<Void, Never>?
    private lazy var hud = HUDController { [weak self] in self?.stop() }
    private let diagrams = DiagramWindowController()
    /// A confirmation that a spoken "sì" / "no" can answer.
    var pendingConfirmation: CommandPanelModel.State?
    /// The current command came from the microphone: feedback is also spoken.
    var isVoiceCommand = false
    /// The request whose reply goes into the conversation once it is known.
    var currentRequest: String?
    /// What a silent action did, for the conversation ("app.open app=Safari").
    var actionSummary: String?
    /// The panel is hidden on purpose while actions drive the Mac (keystrokes must not land in it).
    private var isDrivingMac = false
    /// A result (answer, error, confirmation) arrived while the panel was closed.
    private var hasUnseenResult = false {
        didSet { if hasUnseenResult != oldValue { onUnseenResultChange?(hasUnseenResult) } }
    }
    var onUnseenResultChange: (@MainActor (Bool) -> Void)?
    /// Actions that finished without output (the panel just closes): MCP callers need to tell them from a cancel.
    private(set) var completedSilently = 0
    private var history: CommandHistory
    lazy var panel: CommandPanel = {
        let panel = CommandPanel(
            rootView: CommandPanelView(
                model: model,
                onSubmit: { [weak self] in self?.submit() },
                onCancel: { [weak self] in self?.cancel() },
                onOpenDiagram: { [weak self] in self?.openDiagram($0) }
            )
        )
        panel.onKeyDown = { [weak self] event in self?.handleKey(event) ?? false }
        return panel
    }()

    init(engine: CommandEngine, defaults: UserDefaults = .standard) {
        self.engine = engine
        self.defaults = defaults
        self.history = CommandHistory(entries: defaults.stringArray(forKey: Self.historyKey) ?? [])
    }

    func update(engine: CommandEngine, voice: VoiceSettings) {
        self.engine = engine
        self.voice = voice
    }

    func toggle() {
        if panel.isVisible {
            hide()
        } else {
            show()
        }
    }

    /// Reopening keeps a request in progress and shows a result that arrived while the panel was closed.
    func show() {
        guard !isDrivingMac else { return }
        let keepsState = model.state == .working || model.state == .listening || hasUnseenResult
        hasUnseenResult = false
        if !keepsState {
            model.state = .idle
            history.resetNavigation()
            // Load the System One model while the user is still typing.
            Task { [engine] in await engine.prepare() }
        }
        position()
        panel.makeKeyAndOrderFront(nil)
        model.focusRequest += 1
    }

    func hide() {
        endFollowUp()
        panel.orderOut(nil)
    }

    /// Kill switch: stops listening, speaking and whatever RedOS is doing.
    func stop() {
        speaker.stop()
        hud.hide()
        if listening != nil {
            cancel()
        }
        work?.cancel()
        work = nil
    }

    func start(_ body: @escaping @MainActor () async -> Void) {
        work?.cancel()
        work = Task { [weak self, model] in
            model.activity = nil
            let silent = self?.completedSilently ?? 0
            await ActivityReporter.$handler.withValue({ activity in model.activity = activity }, operation: {
                await body()
            })
            model.activity = nil
            guard let self, !Task.isCancelled else { return }
            await rememberTurn(silentBefore: silent)
            guard !panel.isVisible else {
                followUpIfUseful()
                return
            }
            switch model.state {
            case .answer, .message, .confirming, .confirmingPlan: hasUnseenResult = true
            case .idle, .listening, .working: break
            }
        }
    }

    func submit() {
        endFollowUp()
        switch model.state {
        case .working, .listening:
            return
        case .confirming(let command):
            start { [self, engine] in await run(command.input) { _ in await engine.execute(command) } }
        case .confirmingPlan(let plan):
            start { [self, engine] in await run(plan.input) { await engine.execute(plan, onStep: $0) } }
        case .idle, .message, .answer:
            let input = model.text
            isVoiceCommand = false
            model.state = .working
            start { [self] in await resolve(input) }
        }
    }

    func resolve(_ input: String) async {
        actionSummary = nil
        let resolution = await engine.resolve(input)
        if Task.isCancelled {
            model.state = .idle
            return
        }
        remember(input, resolution)
        await handle(resolution, input: input)
    }

    /// A scheduled or app-launch routine: skipped while the user is busy with RedOS.
    func runRoutine(named name: String) {
        guard listening == nil, model.state != .working, model.state != .listening else { return }
        isVoiceCommand = false
        currentRequest = nil
        start { [self] in
            let resolution = await engine.resolveRoutine(named: name, triggered: true)
            if case .plan(_, true) = resolution {
                show()
            }
            await handle(resolution, input: name)
        }
    }

    private func handle(_ resolution: Resolution, input: String) async {
        switch resolution {
        case .unrecognized:
            fail(String(localized: "I don't know how to do that yet."), spoken: "I don't know how to do that yet.")
        case .unavailable(let reason):
            fail(reason)
        case .invalid(_, let error):
            fail(error.localizedDescription)
        case .denied(let request):
            fail(String(localized: "Action disabled: \(request.actionID)"))
        case .ready(let command, let needsConfirmation):
            actionSummary = CommandEngine.describe(command.request)
            await confirmOrRun(needsConfirmation ? .confirming(command) : nil, input) { [engine] _ in
                await engine.execute(command)
            }
        case .plan(let plan, let needsConfirmation):
            actionSummary = plan.steps.map(CommandEngine.describe).joined(separator: " → ")
            await confirmOrRun(needsConfirmation ? .confirmingPlan(plan) : nil, input) { [engine] in
                await engine.execute(plan, onStep: $0)
            }
        case .agent(let task):
            await run(task) { [engine] in await engine.runAgent(task, onStep: $0) }
        case .research(let question, let query):
            await research(question, query: query)
        case .diagram(let request, let description):
            await diagram(request, description: description)
        case .answer(let text):
            model.state = .answer(.init(text: text))
            say(text)
        }
    }

    private func confirmOrRun(
        _ confirmation: CommandPanelModel.State?, _ title: String,
        _ work: (_ onStep: @escaping StepHandler) async -> Result<String?, ActionError>
    ) async {
        if let confirmation {
            model.state = confirmation
            sayPhrase("Say yes to confirm.")
        } else {
            await run(title, work)
        }
    }

    /// Details stay on screen; the voice gets a short phrase in its own language.
    private func fail(_ message: String, spoken: String = "Something went wrong, details are on screen.") {
        model.state = .message(message, isError: true)
        sayPhrase(spoken)
    }

    func cancel() {
        speaker.stop()
        endFollowUp()
        switch model.state {
        case .listening:
            endpoint.cancel()
            let stopping = listening
            listening?.cancel()
            listening = nil
            // The microphone may still be starting: stop it once it has.
            Task { [listener] in
                await stopping?.value
                await listener.cancel()
            }
            model.state = .idle
        case .confirming(let command):
            Task { [engine] in await engine.cancel(command) }
            model.state = .idle
        case .confirmingPlan(let plan):
            Task { [engine] in await engine.cancel(plan) }
            model.state = .idle
        case .working:
            work?.cancel()
        default:
            break
        }
        hide()
    }
}

extension CommandPanelController {
    /// Hides the panel and shows the HUD while the work drives the Mac; outputs (screen text, command
    /// results, the agent's summary) come back in the panel.
    private func run(
        _ title: String, _ work: (_ onStep: @escaping StepHandler) async -> Result<String?, ActionError>
    ) async {
        model.state = .working
        hide()
        hud.show(title)
        isDrivingMac = true
        // Give focus back to the previous app before posting keyboard or mouse events.
        try? await Task.sleep(for: .milliseconds(150))
        let result = await work { [hud] step, request in
            hud.update("\(step) · \(CommandEngine.describe(request))")
        }
        isDrivingMac = false
        hud.hide()
        switch result {
        case .success(let output?):
            model.state = .idle
            show()
            model.state = .answer(.init(text: output))
            say(String(output.prefix(400)))
        case .success(nil):
            model.text = ""
            model.state = .idle
            completedSilently += 1
        case .failure(.cancelled):
            model.state = .idle
            show()
            model.state = .message(ActionError.cancelled.localizedDescription, isError: false)
            sayPhrase("Stopped.")
        case .failure(let error):
            model.state = .idle
            show()
            fail(error.localizedDescription)
        }
    }

    /// Web research keeps the panel open with the current step; Esc or the kill switch stop it.
    private func research(_ question: String, query: String) async {
        model.state = .working
        switch await engine.runResearch(question, query: query) {
        case .success(let answer):
            model.state = .answer(.init(
                text: answer.text, sources: answer.sourceSites, image: answer.image, chart: answer.chart
            ))
            say(answer.text)
        case .failure(.cancelled):
            model.state = .idle
        case .failure(let error):
            fail(error.localizedDescription)
        }
    }

    /// Diagrams open in their own window; the panel keeps a button to reopen them.
    private func diagram(_ request: String, description: String) async {
        model.state = .working
        switch await engine.runDiagram(request, description: description) {
        case .success(let diagram):
            model.state = .answer(.init(text: diagram.title, diagram: diagram))
            openDiagram(diagram)
        case .failure(.cancelled):
            model.state = .idle
        case .failure(let error):
            fail(error.localizedDescription)
        }
    }

    func openDiagram(_ diagram: Diagram) {
        diagrams.show(diagram)
    }

    /// Model answers, spoken as they are.
    private func say(_ text: String) {
        guard isVoiceCommand, voice.speaksAnswers else { return }
        speaker.speak(text, locale: voice.locale)
    }

    /// App phrases, spoken in the voice language even when the interface uses another one.
    private func sayPhrase(_ key: String) {
        let language = voice.locale.language.languageCode?.identifier ?? "en"
        let bundle = Bundle.main.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:))
        say(bundle?.localizedString(forKey: key, value: key, table: nil) ?? key)
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let upArrow: UInt16 = 126, downArrow: UInt16 = 125
        let modifiers = event.modifierFlags.intersection([.shift, .control, .option, .command])
        guard modifiers.isEmpty, model.state != .working,
              event.keyCode == upArrow || event.keyCode == downArrow
        else { return false }

        let recalled = event.keyCode == upArrow ? history.previous(current: model.text) : history.next()
        if let recalled {
            model.text = recalled
            // Put the caret at the end once SwiftUI has pushed the new text into the field editor.
            DispatchQueue.main.async { [panel] in
                (panel.firstResponder as? NSTextView)?.moveToEndOfDocument(nil)
            }
        }
        return true
    }

    /// Commands carrying sensitive arguments (e.g. typed text) are kept out of the persisted history.
    private func remember(_ input: String, _ resolution: Resolution) {
        let requests: [ActionRequest] = switch resolution {
        case .ready(let command, _): [command.request]
        case .plan(let plan, _): plan.steps
        case .invalid(let request, _), .denied(let request): [request]
        case .unrecognized, .unavailable, .answer, .agent, .research, .diagram: []
        }
        let isSensitive = requests.contains { request in
            engine.registry.action(for: request.actionID)?.parameters
                .contains { $0.isSensitive && request.arguments[$0.name] != nil } ?? false
        }
        if isSensitive {
            currentRequest = nil
            history.resetNavigation()
            return
        }
        currentRequest = input
        history.record(input)
        defaults.set(history.entries, forKey: Self.historyKey)
    }

    private func position() {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        // The card sits at the top of the transparent panel, about a quarter below the top of the screen.
        let top = frame.minY + frame.height * 0.75
        let size = CommandPanelView.size
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: top - size.height))
    }
}
