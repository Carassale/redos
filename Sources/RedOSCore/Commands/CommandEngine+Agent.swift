import Foundation

// MARK: - Screen agent

/// One look at the screen and the agent's decision about it.
struct Observed {
    let step: AgentStep
    let screen: String
    let screenshot: Screenshot?
}

extension CommandEngine {
    /// Fewer listed elements than this: Accessibility shows little (canvas, games, some web apps), so the agent
    /// also gets an image of the window, when allowed.
    static let sparseScreen = 12

    public func cancel(_ command: ResolvedCommand) async {
        await record(command, .cancelled)
    }

    public func cancel(_ plan: ResolvedPlan) async {
        for command in commands(of: plan) {
            await record(command, .cancelled)
        }
    }

    /// Observe-act loop: every step is validated, policy-checked and audited; dangerous actions are refused.
    /// Returns the agent's closing summary.
    public func runAgent(_ task: String, onStep: StepHandler? = nil) async -> Result<String?, ActionError> {
        guard let agent, let observer else { return .failure(.failed(String(localized: "No agent configured."))) }
        let context = await withContext(task)
        var history: [String] = []
        var repeats = 0
        var previous: ActionRequest?
        var succeeded: ActionRequest?
        for number in 1...ModelAgent.maxSteps {
            let proposed: ActionRequest
            let seen: Observed
            switch await nextStep(context, history: history, agent: agent, observer: observer) {
            case .failure(let error): return .failure(error)
            case .success(let observed):
                switch observed.step {
                case .done(let summary): return .success(summary)
                case .act(let next): (proposed, seen) = (next, observed)
                }
            }
            // Small models tend to redo the last step instead of saying done (a second press would undo it).
            if proposed == succeeded, proposed.actionID != "scroll" { return .success(nil) }
            repeats = proposed == previous ? repeats + 1 : 0
            previous = proposed
            guard repeats < 3 else {
                return .failure(.failed(String(localized: "Stopped: the same step kept repeating.")))
            }
            // Element numbers change from screen to screen: the history also names the element.
            let line = Self.describe(proposed) + Self.element(proposed, in: seen.screen)
                + (proposed.actionID == "mouse.click" ? " (screenshot pixels)" : "")
            guard let request = Self.onScreen(proposed, seen.screenshot), isAllowedForAgent(request) else {
                history.append("\(line) -> refused: not allowed for the agent")
                continue
            }
            await onStep?(number, request)
            let result = await execute(ResolvedCommand(input: task, request: request, route: .agent, confidence: nil))
            if case .failure(.cancelled) = result { return .failure(.cancelled) }
            let entry = Self.historyEntry(line, result)
            succeeded = entry.ok ? proposed : nil
            history.append(entry.text)
            // Let the app react (menus opening, pages loading) before looking again.
            try? await Task.sleep(for: .milliseconds(600))
        }
        return .failure(.failed(String(localized: "Stopped: the task needs too many steps.")))
    }

    private static func historyEntry(
        _ line: String, _ result: Result<String?, ActionError>
    ) -> (text: String, ok: Bool) {
        switch result {
        case .success(let output): ("\(line) -> ok" + (output.map { ": \($0.prefix(300))" } ?? ""), true)
        case .failure(let error): ("\(line) -> failed: \(error.localizedDescription)", false)
        }
    }

    /// "ui.press target=#3" for the agent history and the HUD.
    public static func describe(_ request: ActionRequest) -> String {
        let arguments = request.arguments.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        return ([request.actionID] + arguments).joined(separator: " ")
    }

    /// " (menu \"File\")" for a "#2" target listed on `screen`.
    static func element(_ request: ActionRequest, in screen: String) -> String {
        guard let target = request.arguments["target"], target.hasPrefix("#"),
              let line = screen.split(separator: "\n").first(where: { $0.hasPrefix("[\(target.dropFirst())] ") })
        else { return "" }
        return " (\(line.drop { $0 != " " }.dropFirst()))"
    }

    /// A click by position is in screenshot pixels: it becomes a left click on screen, only inside the window
    /// shown. Without a screenshot the agent may not click by position.
    static func onScreen(_ request: ActionRequest, _ screenshot: Screenshot?) -> ActionRequest? {
        guard request.actionID == "mouse.click" else { return request }
        guard let screenshot,
              let x = request.arguments["x"].flatMap(Double.init), let y = request.arguments["y"].flatMap(Double.init),
              let point = screenshot.screenPoint(x: Int(x), y: Int(y))
        else { return nil }
        return ActionRequest("mouse.click", ["x": String(Int(point.x)), "y": String(Int(point.y))])
    }

    /// The image helps when Accessibility lists little or the last step did not work.
    static func needsScreenshot(_ screen: String, history: [String]) -> Bool {
        if let last = history.last, last.contains("-> failed") || last.contains("-> refused") { return true }
        return JevAgent.elements(in: screen).count < sparseScreen
    }

    private func nextStep(
        _ task: String, history: [String], agent: any Acting, observer: any ScreenObserving
    ) async -> Result<Observed, ActionError> {
        if Task.isCancelled { return .failure(.cancelled) }
        do {
            let screen = try await observer.observe()
            let screenshot = Self.needsScreenshot(screen, history: history) ? await observer.screenshot() : nil
            let step = try await agent.next(
                task: task, history: history, screen: screen, screenshot: screenshot, registry: registry
            )
            return .success(Observed(step: step, screen: screen, screenshot: screenshot))
        } catch {
            if Task.isCancelled { return .failure(.cancelled) }
            let actionError = error as? ActionError ?? .failed(error.localizedDescription)
            await record(task, nil, .failed, route: .agent, error: actionError)
            return .failure(actionError)
        }
    }

    private func isAllowedForAgent(_ request: ActionRequest) -> Bool {
        guard ModelAgent.allowedActions.contains(request.actionID) || request.actionID == "mouse.click" else {
            return false
        }
        guard let action = registry.action(for: request.actionID) else { return true }
        return action.risk < .dangerous && policy.decide(for: action) != .deny
    }
}
