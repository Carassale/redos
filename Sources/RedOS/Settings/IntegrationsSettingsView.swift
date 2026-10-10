import AppKit
import RedOSCore
import SwiftUI

/// MCP: RedOS as a server for other apps, and the external servers RedOS uses.
struct IntegrationsSettingsView: View {
    let controller: AppController
    @Binding var settings: AppSettings
    @State private var configuration = MCPConfiguration.load()
    @State private var newName = ""
    @State private var newCommand = ""
    @State private var isConnecting = false

    var body: some View {
        Form {
            serverSection
            clientSection
        }
        .formStyle(.grouped)
    }

    private var serverSection: some View {
        Section {
            Toggle("Let other apps control RedOS", isOn: $settings.mcpServerEnabled)
            if settings.mcpServerEnabled {
                LabeledContent("Address") {
                    Text(verbatim: controller.mcpURL).textSelection(.enabled).foregroundStyle(.secondary)
                }
                Toggle("Allow reading the screen", isOn: $settings.mcpAllowsScreenReading)
                HStack {
                    Button("Copy for VS Code") { copy(vsCodeConfiguration) }
                    Button("Copy for Claude Code") { copy(claudeCommand) }
                    Spacer()
                    Button("New Token", role: .destructive) { controller.regenerateMCPToken() }
                }
                if let error = controller.mcpServerError {
                    Text(verbatim: error).foregroundStyle(.red)
                }
            }
        } header: {
            Text("RedOS as MCP server")
        } footer: {
            Text(Self.serverFooter).font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var clientSection: some View {
        Section {
            ForEach(configuration.mcpServers.keys.sorted(), id: \.self) { name in
                serverRow(name)
            }
            HStack {
                TextField("Name", text: $newName).frame(width: 120)
                TextField("Command, e.g. npx -y @modelcontextprotocol/server-memory", text: $newCommand)
                Button("Add") { add() }
                    .disabled(newName.isEmpty || newCommand.isEmpty)
            }
            .labelsHidden()
            HStack {
                Button("Open mcp.json") { openConfiguration() }
                Button("Reconnect") { reconnect() }
                if isConnecting { ProgressView().controlSize(.small) }
            }
        } header: {
            Text("MCP servers used by RedOS")
        } footer: {
            Text(Self.clientFooter).font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func serverRow(_ name: String) -> some View {
        let config = configuration.mcpServers[name]
        let status = controller.mcpStatuses.first { $0.name == name }
        return HStack {
            VStack(alignment: .leading) {
                Text(verbatim: name)
                Text(verbatim: ([config?.command ?? ""] + (config?.args ?? [])).joined(separator: " "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                if let error = status?.error {
                    Text(verbatim: error).font(.caption).foregroundStyle(.red).lineLimit(2)
                } else if config?.disabled == true {
                    Text("Off").font(.caption).foregroundStyle(.secondary)
                } else if let status {
                    Text("\(status.tools.count) tools").font(.caption).foregroundStyle(.secondary)
                        .help(status.tools.joined(separator: ", "))
                }
            }
            Spacer()
            Toggle("Enabled", isOn: Binding(
                get: { config?.disabled != true },
                set: { enabled in update { $0.mcpServers[name]?.disabled = enabled ? nil : true } }
            ))
            .labelsHidden()
            Button("Remove", role: .destructive) { update { $0.mcpServers[name] = nil } }
        }
        .controlSize(.small)
    }

    private func add() {
        let words = Self.split(newCommand)
        guard let command = words.first else { return }
        let name = newName.trimmingCharacters(in: .whitespaces)
        update { $0.mcpServers[name] = MCPServerConfig(command: command, args: Array(words.dropFirst())) }
        newName = ""
        newCommand = ""
    }

    private func update(_ change: (inout MCPConfiguration) -> Void) {
        change(&configuration)
        try? configuration.save()
        reconnect()
    }

    private func reconnect() {
        configuration = MCPConfiguration.load()
        isConnecting = true
        controller.reloadMCPServers()
        Task {
            // Servers started with npx/uvx may first download their package.
            try? await Task.sleep(for: .seconds(3))
            isConnecting = false
        }
    }

    private func openConfiguration() {
        let url = MCPConfiguration.defaultURL
        if !FileManager.default.fileExists(atPath: url.path) { try? configuration.save() }
        NSWorkspace.shared.open(url)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private var vsCodeConfiguration: String {
        """
        "redos": {
          "type": "http",
          "url": "\(controller.mcpURL)",
          "headers": { "Authorization": "Bearer \(controller.mcpToken)" }
        }
        """
    }

    private var claudeCommand: String {
        "claude mcp add --transport http redos \(controller.mcpURL) "
            + "--header \"Authorization: Bearer \(controller.mcpToken)\""
    }

    /// Splits a command line on spaces, keeping "quoted parts" together.
    static func split(_ line: String) -> [String] {
        var words: [String] = [], current = "", quote: Character?
        for character in line {
            if let open = quote {
                if character == open { quote = nil } else { current.append(character) }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == " " {
                if !current.isEmpty { words.append(current) }
                current = ""
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { words.append(current) }
        return words
    }

    private static let serverFooter: LocalizedStringKey = """
        VS Code, Claude and other MCP clients on this Mac can send commands to RedOS (tool run_command). \
        Only local connections with the token are accepted; actions that change things still ask you to confirm.
        """

    private static let clientFooter: LocalizedStringKey = """
        Tools of these servers are available to the assistant in multi-step requests. Read-only tools run \
        directly; the others ask for confirmation. Same format as Claude Desktop's mcpServers.
        """
}
