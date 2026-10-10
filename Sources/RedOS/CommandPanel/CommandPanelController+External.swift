import RedOSCore

extension CommandPanelController {
    /// A command from an MCP client, handled as if typed (same confirmations); returns how it ended.
    func runExternal(_ text: String) async -> MCPToolResult {
        endFollowUp()
        guard listening == nil, model.state != .working, model.state != .listening else {
            return MCPToolResult(String(localized: "RedOS is busy with another request."), isError: true)
        }
        show()
        let completed = completedSilently
        model.text = text
        submit()
        let deadline = ContinuousClock.now + .seconds(600)
        while !Task.isCancelled, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(200))
            switch model.state {
            case .working, .listening, .confirming, .confirmingPlan:
                continue
            case .answer(let answer):
                let extras = answer.sources + [answer.diagram.map { "Diagram: \($0.file.path)" }].compactMap(\.self)
                return MCPToolResult(([answer.text] + extras).joined(separator: "\n"))
            case .message(let message, let isError):
                return MCPToolResult(message, isError: isError)
            case .idle where completedSilently > completed:
                return MCPToolResult(String(localized: "Done."))
            case .idle:
                return MCPToolResult(String(localized: "Cancelled by the user."), isError: true)
            }
        }
        return MCPToolResult(String(localized: "No answer from RedOS in time."), isError: true)
    }
}
