import AppKit
import RedOSCore

@MainActor
final class CommandPanelController {
    private let engine: CommandEngine
    private let model = CommandPanelModel()
    private lazy var panel = CommandPanel(
        rootView: CommandPanelView(
            model: model,
            onSubmit: { [weak self] in self?.submit() },
            onCancel: { [weak self] in self?.cancel() }
        )
    )

    init(engine: CommandEngine) {
        self.engine = engine
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
        position()
        panel.makeKeyAndOrderFront(nil)
        model.focusRequest += 1
        // Load the System One model while the user is still typing.
        Task { [engine] in await engine.prepare() }
    }

    private func hide() {
        panel.orderOut(nil)
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
        switch await engine.resolve(input) {
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
