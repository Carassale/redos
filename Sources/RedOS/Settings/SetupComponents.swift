import AppKit
import RedOSCore
import SwiftUI

/// Ollama status with the next step: download, start, or download the missing models.
struct OllamaStatusRows: View {
    let ollama: OllamaSetup
    let wanted: [String]

    var body: some View {
        LabeledContent("Ollama") {
            HStack {
                if ollama.isRunning {
                    Text("Running · \(ollama.installed?.count ?? 0) models").foregroundStyle(.secondary)
                } else if ollama.isInstalledOnMac {
                    Text("Not running").foregroundStyle(.orange)
                    Button("Start") { Task { await ollama.start() } }.disabled(ollama.isStarting)
                    if ollama.isStarting { ProgressView().controlSize(.small) }
                } else {
                    Text("Not installed").foregroundStyle(.orange)
                    Link("Download Ollama", destination: OllamaSetup.downloadURL)
                }
                Button { Task { await ollama.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Refresh")
            }
        }
        let missing = ollama.missing(wanted)
        if missing.count > 1, missing.allSatisfy({ ollama.downloads[$0] == nil }) {
            Button("Download All Models") { Task { await ollama.download(missing) } }
        }
        ForEach(missing, id: \.self) { model in
            LabeledContent {
                if let fraction = ollama.downloads[model] {
                    ProgressView(value: fraction).frame(width: 140)
                } else {
                    Button("Download") { Task { await ollama.download([model]) } }
                }
            } label: {
                Label("\(model) is not installed", systemImage: "arrow.down.circle")
            }
        }
        if let error = ollama.error {
            Text(verbatim: error).foregroundStyle(.red)
        }
    }
}

/// How to get the provider ready: an API key link, or how to install the Copilot CLI.
struct ProviderHelp: View {
    let provider: SystemTwoProvider
    @Binding var copilotPath: String
    @State private var isDetecting = false

    static let copilotInstall = "npm install -g @github/copilot"
    private static let copilotSteps: LocalizedStringKey = """
        Install the GitHub Copilot CLI in Terminal (needs Node.js and a Copilot subscription), \
        then run “copilot” once to sign in:
        """

    var body: some View {
        if let url = provider.keyURL {
            Link("Get an API key", destination: url)
        }
        if provider == .copilot, !FileManager.default.isExecutableFile(atPath: copilotPath) {
            VStack(alignment: .leading, spacing: 6) {
                Text(Self.copilotSteps)
                HStack {
                    Text(verbatim: Self.copilotInstall).font(.body.monospaced()).textSelection(.enabled)
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(Self.copilotInstall, forType: .string)
                    }
                    Spacer()
                    Button("Detect") {
                        Task {
                            isDetecting = true
                            if let url = await CopilotCLIClient.locate() { copilotPath = url.path }
                            isDetecting = false
                        }
                    }
                    .disabled(isDetecting)
                }
            }
            .font(.callout)
        }
    }
}

extension SystemTwoProvider {
    /// Where to create an API key.
    var keyURL: URL? {
        switch self {
        case .openAI: URL(string: "https://platform.openai.com/api-keys")
        case .anthropic: URL(string: "https://console.anthropic.com/settings/keys")
        case .gemini: URL(string: "https://aistudio.google.com/apikey")
        case .ollama, .copilot: nil
        }
    }
}

/// A small planning request that checks provider, model and credentials end to end.
enum AssistantCheck {
    @MainActor
    static func run(_ settings: AppSettings, apiKey: String, registry: ActionRegistry) async -> SettingsStatus {
        do {
            let start = ContinuousClock.now
            let planner = ModelPlanner(client: try settings.systemTwo(apiKey: apiKey).client())
            let result = try await planner.plan("apri Safari e vai su apple.com", registry: registry)
            let seconds = (ContinuousClock.now - start)
                .formatted(.units(allowed: [.seconds], fractionalPart: .show(length: 1)))
            let steps = result.steps.map(\.actionID).joined(separator: " → ")
            return .info(String(localized: "OK in \(seconds): \(steps.isEmpty ? result.answer ?? "-" : steps)"))
        } catch {
            return .error(error.localizedDescription)
        }
    }
}

/// The Test button with its result.
struct AssistantTestRow: View {
    let run: () async -> SettingsStatus
    @State private var status: SettingsStatus?
    @State private var isTesting = false

    var body: some View {
        HStack {
            Button("Test") {
                Task {
                    isTesting = true
                    status = nil
                    status = await run()
                    isTesting = false
                }
            }
            .disabled(isTesting)
            if isTesting { ProgressView().controlSize(.small) }
            switch status {
            case .info(let text): Text(verbatim: text).foregroundStyle(.secondary).lineLimit(2)
            case .error(let text): Text(verbatim: text).foregroundStyle(.red).lineLimit(2)
            case nil: EmptyView()
            }
        }
    }
}
