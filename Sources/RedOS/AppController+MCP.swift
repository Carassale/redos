import AppKit
import RedOSActions
import RedOSCore

/// RedOS as an MCP server (other apps send it commands) and as an MCP client (System Two uses other
/// servers' tools).
extension AppController {
    static let mcpTokenAccount = "mcp.server.token"

    var mcpURL: String { "http://127.0.0.1:\(settings.mcpServerPort)/mcp" }

    /// The bearer token MCP clients must send; created on first use.
    var mcpToken: String {
        if let token = Keychain.secret(for: Self.mcpTokenAccount), !token.isEmpty { return token }
        let token = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        try? Keychain.setSecret(token, for: Self.mcpTokenAccount)
        return token
    }

    func regenerateMCPToken() {
        try? Keychain.setSecret(nil, for: Self.mcpTokenAccount)
        mcpServerKey = ""
        configureMCPServer(settings)
    }

    func configureMCPServer(_ settings: AppSettings) {
        let token = settings.mcpServerEnabled ? mcpToken : ""
        let key = "\(settings.mcpServerEnabled)|\(settings.mcpServerPort)|\(settings.mcpAllowsScreenReading)|\(token)"
        guard key != mcpServerKey else { return }
        mcpServerKey = key
        mcpServer?.stop()
        mcpServer = nil
        mcpServerError = nil
        guard settings.mcpServerEnabled, let port = UInt16(exactly: settings.mcpServerPort) else { return }
        var tools = [commandTool]
        if settings.mcpAllowsScreenReading { tools.append(screenTool) }
        let endpoint = MCPHTTPEndpoint(
            server: MCPServer(
                name: "RedOS", version: AppInfo.version, instructions: Self.mcpInstructions, tools: tools
            ),
            token: token, port: port
        )
        do {
            let server = try LocalHTTPServer(port: port) { await endpoint.respond($0) }
            server.start { [weak self] error in
                // Right after a restart the old process may still hold the port: try again shortly.
                Task { @MainActor in
                    guard let self, self.mcpServer === server else { return }
                    self.mcpServerError = error
                    try? await Task.sleep(for: .seconds(3))
                    guard self.mcpServer === server else { return }
                    self.mcpServerKey = ""
                    self.configureMCPServer(self.settings)
                }
            }
            mcpServer = server
        } catch {
            mcpServerError = error.localizedDescription
        }
    }

    /// Starts the servers in mcp.json and offers their tools to System Two.
    func reloadMCPServers() {
        Task {
            await mcpHub.update(MCPConfiguration.load())
            let actions = await mcpHub.allActions
            mcpStatuses = await mcpHub.statuses
            guard actions.map(\.id) != mcpActions.map(\.id) else { return }
            mcpActions = actions
            rebuildEngine(settings)
        }
    }

    private static let mcpInstructions = """
        RedOS controls this Mac. Use run_command for anything on the Mac: open or quit apps and websites, \
        press buttons and fill fields in apps, type text, run routines, or ask a question. \
        Commands that change things wait for the user to confirm in RedOS.
        """

    private var commandTool: MCPServerTool {
        MCPServerTool(
            name: "run_command",
            description: "Runs a command on the user's Mac through RedOS, as if typed in its panel "
                + "(English or Italian), e.g. \"open Safari and go to apple.com\", \"quit Slack\", "
                + "\"press the Save button\". Returns RedOS's answer or the outcome.",
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "command": .object(["type": "string", "description": "The command in natural language."]),
                ]),
                "required": .array(["command"]),
            ]),
            isReadOnly: false
        ) { [weak self] arguments in
            guard let command = arguments["command"]?.string, !command.isEmpty else {
                return MCPToolResult("Missing command.", isError: true)
            }
            return await self?.commandPanel.runExternal(command) ?? MCPToolResult("RedOS quit.", isError: true)
        }
    }

    private var screenTool: MCPServerTool {
        MCPServerTool(
            name: "read_screen",
            description: "Returns the text of the frontmost window on the user's Mac (app, title, web address "
                + "and visible text), read through Accessibility.",
            inputSchema: .object(["type": "object", "properties": .object([:])]),
            isReadOnly: true
        ) { _ in
            await MainActor.run {
                guard let content = AccessibilityObserver().screenContent() else {
                    let error = ActionError.permissionMissing(.accessibility)
                    return MCPToolResult(error.localizedDescription, isError: true)
                }
                let header = ["App: \(content.app)", content.window.map { "Window: \($0)" },
                              content.address.map { "Address: \($0)" }].compactMap(\.self)
                return MCPToolResult((header + ["", content.text]).joined(separator: "\n"))
            }
        }
    }
}
