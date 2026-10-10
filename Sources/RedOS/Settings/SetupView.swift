import RedOSCore
import RedOSVoice
import SwiftUI

/// First-run checklist: permissions, local models, assistant, voice. Each step shows what is missing and
/// the button that fixes it.
struct SetupView: View {
    let controller: AppController
    @Binding var settings: AppSettings
    @Binding var apiKey: String
    @Binding var pane: SettingsPane?
    @State private var speechInstalled: Bool?
    @State private var isInstallingSpeech = false
    @State private var speechError: String?

    static let seenKey = "setup.seen"

    private var ollama: OllamaSetup { controller.ollama }

    var body: some View {
        Form {
            Section {
                Text("Complete these steps to start using RedOS. You can change everything later.")
                    .foregroundStyle(.secondary)
            }
            Section {
                ForEach(Permission.allCases) { permission in
                    PermissionRow(
                        permission: permission,
                        status: controller.permissions.status(of: permission),
                        onRequest: { Task { await controller.permissions.request(permission) } }
                    )
                }
            } header: {
                StepHeader(number: 1, title: "Permissions", isDone: controller.permissions.allGranted)
            }
            Section {
                OllamaStatusRows(ollama: ollama, wanted: settings.localModels)
            } header: {
                StepHeader(number: 2, title: "Local models", isDone: isOllamaReady)
            } footer: {
                Text(Self.ollamaFooter).font(.footnote).foregroundStyle(.secondary)
            }
            assistantSection
            voiceSection
        }
        .formStyle(.grouped)
        .onAppear { UserDefaults.standard.set(true, forKey: Self.seenKey) }
        .task {
            // Permissions and Ollama change outside RedOS: keep the checklist current.
            while !Task.isCancelled {
                controller.permissions.refresh()
                await ollama.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .task(id: settings.voiceLocale) {
            speechInstalled = await SpeechListener.isInstalled(Locale(identifier: settings.voiceLocale))
        }
    }

    private var isOllamaReady: Bool {
        ollama.isRunning && ollama.missing(settings.localModels).isEmpty
    }

    private var isAssistantReady: Bool {
        switch settings.systemTwoProvider {
        case .ollama: ollama.has(settings.systemTwoModel)
        case .copilot: FileManager.default.isExecutableFile(atPath: settings.copilotPath)
        case .openAI, .anthropic, .gemini: !apiKey.isEmpty
        }
    }

    private var assistantSection: some View {
        Section {
            Picker("Provider", selection: $settings.systemTwoProvider) {
                ForEach(SystemTwoProvider.allCases) { Text($0.displayName).tag($0) }
            }
            switch settings.systemTwoProvider {
            case .ollama:
                Text("Uses the local model: no account needed, nothing leaves this Mac.").foregroundStyle(.secondary)
            case .copilot:
                if isAssistantReady {
                    LabeledContent("Copilot CLI") { Text(verbatim: settings.copilotPath).foregroundStyle(.secondary) }
                }
            case .openAI, .anthropic, .gemini:
                SecureField("API key", text: $apiKey)
            }
            ProviderHelp(provider: settings.systemTwoProvider, copilotPath: $settings.copilotPath)
            HStack {
                AssistantTestRow { [settings, apiKey, controller] in
                    await AssistantCheck.run(settings, apiKey: apiKey, registry: controller.registry)
                }
                Spacer()
                Button("More Options…") { pane = .models }
            }
        } header: {
            StepHeader(number: 3, title: "Assistant", isDone: isAssistantReady)
        } footer: {
            Text(Self.assistantFooter).font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var voiceSection: some View {
        Section {
            LabeledContent("Speech recognition") {
                HStack {
                    switch speechInstalled {
                    case true?:
                        Text("Installed").foregroundStyle(.secondary)
                    case false?:
                        if isInstallingSpeech {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("Download") { Task { await installSpeech() } }
                        }
                    case nil:
                        ProgressView().controlSize(.small)
                    }
                }
            }
            if let speechError {
                Text(verbatim: speechError).foregroundStyle(.red)
            }
            Toggle("Listen for “Hey Red”", isOn: $settings.wakeWordEnabled)
            if settings.wakeWordEnabled, let error = controller.wakeWordError {
                Text(verbatim: error).foregroundStyle(.red)
            }
        } header: {
            StepHeader(number: 4, title: "Voice", isDone: speechInstalled == true)
        } footer: {
            Text(Self.voiceFooter).font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func installSpeech() async {
        isInstallingSpeech = true
        defer { isInstallingSpeech = false }
        speechError = nil
        let locale = Locale(identifier: settings.voiceLocale)
        do {
            try await SpeechListener.install(locale)
        } catch {
            speechError = error.localizedDescription
        }
        speechInstalled = await SpeechListener.isInstalled(locale)
    }

    private static let voiceFooter: LocalizedStringKey = """
        The speech model for the language chosen in General is downloaded once and works offline. \
        The wake word model is included.
        """

    private static let ollamaFooter: LocalizedStringKey = """
        Ollama runs the models that understand commands on this Mac. After installing it, open it once. \
        The two models take about 10 GB.
        """

    private static let assistantFooter: LocalizedStringKey = """
        Questions, multi-step tasks, screen questions and diagrams go to the assistant. \
        Ollama keeps everything on this Mac; cloud providers are faster and more accurate.
        """
}

private struct StepHeader: View {
    let number: Int
    let title: LocalizedStringKey
    let isDone: Bool

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: isDone ? "checkmark.circle.fill" : "\(number).circle")
                .foregroundStyle(isDone ? .green : .secondary)
        }
    }
}
