import AppKit
import RedOSCore

@MainActor
final class CommandPanelController {
    private static let historyKey = "commandHistory"

    private let engine: CommandEngine
    private let defaults: UserDefaults
    private let model = CommandPanelModel()
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
        let request: ActionRequest? = switch resolution {
        case .ready(let command, _): command.request
        case .invalid(let request, _), .denied(let request): request
        case .unrecognized, .unavailable: nil
        }
        if let request, let action = engine.registry.action(for: request.actionID),
           action.parameters.contains(where: { $0.isSensitive && request.arguments[$0.name] != nil }) {
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
        case .working:
            return
        case .confirming(let command):
            Task { await run(command) }
        case .idle, .message:
            let input = model.text
            model.state = .working
            Task { await resolve(input) }
        }
    }

    private func resolve(_ input: String) async {
        let resolution = await engine.resolve(input)
        remember(input, resolution)
        switch resolution {
        case .unrecognized:
            model.state = .message(
                String(localized: "I'm not sure what to do. Complex requests will be handled by System Two."),
                isError: true
            )
        case .unavailable(let reason):
            model.state = .message(reason, isError: true)
        case .invalid(_, let error):
            model.state = .message(error.localizedDescription, isError: true)
        case .denied(let request):
            model.state = .message(String(localized: "Action disabled: \(request.actionID)"), isError: true)
        case .ready(let command, let needsConfirmation):
            if needsConfirmation {
                model.state = .confirming(command)
            } else {
                await run(command)
            }
        }
    }

    private func run(_ command: ResolvedCommand) async {
        model.state = .working
        hide()
        // Give focus back to the previous app before posting keyboard or mouse events.
        try? await Task.sleep(for: .milliseconds(150))
        switch await engine.execute(command) {
        case .success:
            model.text = ""
            model.state = .idle
        case .failure(let error):
            model.state = .idle
            show()
            model.state = .message(error.localizedDescription, isError: true)
        }
    }

    private func cancel() {
        if case .confirming(let command) = model.state {
            Task { [engine] in await engine.cancel(command) }
            model.state = .idle
        }
        hide()
    }
}
