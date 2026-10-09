import AppKit
import RedOSCore
import RedOSVoice

struct VoiceSettings: Equatable {
    var locale: Locale
    var speaksAnswers: Bool
}

@MainActor
final class CommandPanelController {
    private static let historyKey = "commandHistory"

    private var engine: CommandEngine
    private var voice = VoiceSettings(locale: Locale(identifier: "en_US"), speaksAnswers: true)
    private let defaults: UserDefaults
    private let model = CommandPanelModel()
    private let listener = SpeechListener()
    private let speaker = Speaker()
    private var listening: Task<Void, Never>?
    /// The command being resolved or run: the kill switch cancels it.
    private var work: Task<Void, Never>?
    private lazy var hud = HUDController { [weak self] in self?.stop() }
    /// A confirmation that a spoken "sì" / "no" can answer.
    private var pendingConfirmation: CommandPanelModel.State?
    /// The current command came from the microphone: feedback is also spoken.
    private var isVoiceCommand = false
    private var history: CommandHistory
    private lazy var panel: CommandPanel = {
        let panel = CommandPanel(
            rootView: CommandPanelView(
                model: model,
                onSubmit: { [weak self] in self?.submit() },
                onCancel: { [weak self] in self?.cancel() }
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

    func show() {
        if model.state == .working { return }
        model.state = .idle
        history.resetNavigation()
        position()
        panel.makeKeyAndOrderFront(nil)
        model.focusRequest += 1
        // Load the System One model while the user is still typing.
        Task { [engine] in await engine.prepare() }
    }

    private func hide() {
        panel.orderOut(nil)
    }

    /// Push-to-talk pressed: listen and show the live transcript.
    func startListening() {
        guard listening == nil, model.state != .working else { return }
        guard SystemPermissionChecker().status(of: .microphone) == .granted else {
            show()
            model.state = .message(ActionError.permissionMissing(.microphone).localizedDescription, isError: true)
            return
        }
        speaker.stop()
        pendingConfirmation = switch model.state {
        case .confirming, .confirmingPlan: model.state
        default: nil
        }
        show()
        model.text = ""
        model.state = .listening
        listener.onTranscript = { [weak self] text in self?.model.text = text }
        listener.onDownload = { [weak self] in
            self?.model.state = .message(String(localized: "Downloading the speech model…"), isError: false)
        }
        listening = Task { [listener, voice] in
            do {
                try await listener.start(locale: voice.locale)
                if case .message = model.state { model.state = .listening }
            } catch {
                model.state = .message(error.localizedDescription, isError: true)
            }
        }
    }

    /// Push-to-talk released: the transcript is submitted like a typed command.
    func stopListening() {
        guard let listening else { return }
        self.listening = nil
        start { [self] in
            await listening.value
            guard model.state == .listening else { return }
            // Dictation ends sentences with a period: "apri Safari." must still match the app name.
            var text = await listener.stop()
            if text.hasSuffix(".") { text.removeLast() }
            model.text = text
            guard !text.isEmpty else {
                model.state = .message(String(localized: "I didn't hear anything."), isError: true)
                return
            }
            isVoiceCommand = true
            if let pending = pendingConfirmation, let confirmed = ConfirmationReply.parse(text) {
                pendingConfirmation = nil
                model.state = pending
                if confirmed {
                    submit()
                } else {
                    cancel()
                }
                return
            }
            pendingConfirmation = nil
            model.state = .working
            await resolve(text)
        }
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

    private func start(_ body: @escaping @MainActor () async -> Void) {
        work?.cancel()
        work = Task { await body() }
    }

    private func submit() {
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

    private func resolve(_ input: String) async {
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
            await confirmOrRun(needsConfirmation ? .confirming(command) : nil, input) { [engine] _ in
                await engine.execute(command)
            }
        case .plan(let plan, let needsConfirmation):
            await confirmOrRun(needsConfirmation ? .confirmingPlan(plan) : nil, input) { [engine] in
                await engine.execute(plan, onStep: $0)
            }
        case .agent(let task):
            await run(task) { [engine] in await engine.runAgent(task, onStep: $0) }
        case .research(let question, let query):
            await research(question, query: query)
        case .answer(let text):
            model.state = .answer(text)
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

    /// Hides the panel and shows the HUD while the work drives the Mac; outputs (screen text, command
    /// results, the agent's summary) come back in the panel.
    private func run(
        _ title: String, _ work: (_ onStep: @escaping StepHandler) async -> Result<String?, ActionError>
    ) async {
        model.state = .working
        hide()
        hud.show(title)
        // Give focus back to the previous app before posting keyboard or mouse events.
        try? await Task.sleep(for: .milliseconds(150))
        let result = await work { [hud] step, request in
            hud.update("\(step) · \(CommandEngine.describe(request))")
        }
        hud.hide()
        switch result {
        case .success(let output?):
            model.state = .idle
            show()
            model.state = .answer(output)
            say(String(output.prefix(400)))
        case .success(nil):
            model.text = ""
            model.state = .idle
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

    private func cancel() {
        speaker.stop()
        switch model.state {
        case .listening:
            listening?.cancel()
            listening = nil
            Task { [listener] in await listener.cancel() }
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
    /// Web research keeps the panel open with the current step; Esc or the kill switch stop it.
    private func research(_ question: String, query: String) async {
        model.state = .working
        let result = await engine.runResearch(question, query: query) { [model] step in model.progress = step }
        model.progress = nil
        switch result {
        case .success(let answer):
            model.state = .answer(answer.display)
            say(answer.text)
        case .failure(.cancelled):
            model.state = .idle
        case .failure(let error):
            fail(error.localizedDescription)
        }
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
        case .unrecognized, .unavailable, .answer, .agent, .research: []
        }
        let isSensitive = requests.contains { request in
            engine.registry.action(for: request.actionID)?.parameters
                .contains { $0.isSensitive && request.arguments[$0.name] != nil } ?? false
        }
        if isSensitive {
            history.resetNavigation()
            return
        }
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
