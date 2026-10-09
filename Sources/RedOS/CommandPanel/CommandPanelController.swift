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
        Task {
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
            model.state = .working
            await resolve(text)
        }
    }

    private func say(_ text: String) {
        guard isVoiceCommand, voice.speaksAnswers else { return }
        speaker.speak(text, locale: voice.locale)
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
        case .plan(let plan): plan.steps
        case .invalid(let request, _), .denied(let request): [request]
        case .unrecognized, .unavailable, .answer: []
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
        let size = panel.contentViewController?.preferredContentSize ?? NSSize(width: 640, height: 64)
        let frame = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.minY + frame.height * 0.7))
    }

    private func submit() {
        switch model.state {
        case .working, .listening:
            return
        case .confirming(let command):
            Task { await run { [engine] in await engine.execute(command) } }
        case .confirmingPlan(let plan):
            Task { await run { [engine] in await engine.execute(plan) } }
        case .idle, .message, .answer:
            let input = model.text
            isVoiceCommand = false
            model.state = .working
            Task { await resolve(input) }
        }
    }

    private func resolve(_ input: String) async {
        let resolution = await engine.resolve(input)
        remember(input, resolution)
        switch resolution {
        case .unrecognized:
            fail(String(localized: "I don't know how to do that yet."))
        case .unavailable(let reason):
            fail(reason)
        case .invalid(_, let error):
            fail(error.localizedDescription)
        case .denied(let request):
            fail(String(localized: "Action disabled: \(request.actionID)"))
        case .ready(let command, let needsConfirmation):
            if needsConfirmation {
                model.state = .confirming(command)
                say(String(localized: "Press Return to confirm."))
            } else {
                await run { [engine] in await engine.execute(command) }
            }
        case .plan(let plan):
            model.state = .confirmingPlan(plan)
            say(String(localized: "Press Return to confirm."))
        case .answer(let text):
            model.state = .answer(text)
            say(text)
        }
    }

    private func fail(_ message: String) {
        model.state = .message(message, isError: true)
        say(message)
    }

    private func run(_ work: () async -> Result<Void, ActionError>) async {
        model.state = .working
        hide()
        // Give focus back to the previous app before posting keyboard or mouse events.
        try? await Task.sleep(for: .milliseconds(150))
        switch await work() {
        case .success:
            model.text = ""
            model.state = .idle
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
        default:
            break
        }
        hide()
    }
}
