import RedOSCore
import RedOSVoice
import SwiftUI

struct SettingsView: View {
    let controller: AppController
    @State private var settings = AppSettings()
    @State private var apiKey = ""
    @State private var models: [String] = []
    @State private var status: Status?
    @State private var isBusy = false
    @State private var voiceLocales: [String] = []

    enum Status: Equatable {
        case info(String)
        case error(String)
    }

    var body: some View {
        Form {
            Section("System One (local, Ollama)") {
                TextField("Decision model", text: $settings.systemOneModel)
                TextField("Argument model", text: $settings.extractionModel)
                LabeledContent("Minimum probability to act") {
                    HStack {
                        Slider(value: $settings.threshold, in: 0.3...0.95, step: 0.05)
                        Text(settings.threshold, format: .number.precision(.fractionLength(2)))
                            .monospacedDigit()
                    }
                }
            }

            Section {
                Picker("Language", selection: $settings.voiceLocale) {
                    ForEach(voiceLocales, id: \.self) { identifier in
                        Text(Locale.current.localizedString(forIdentifier: identifier) ?? identifier).tag(identifier)
                    }
                }
                Toggle("Speak answers", isOn: $settings.speaksAnswers)
            } header: {
                Text("Voice")
            } footer: {
                Text("Hold ⌃⌥Space and speak; release to send. Speech is recognized on this Mac.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Provider", selection: $settings.systemTwoProvider) {
                    ForEach(SystemTwoProvider.allCases) { Text($0.displayName).tag($0) }
                }
                HStack {
                    TextField("Model", text: $settings.systemTwoModel)
                    Menu("Models") {
                        if models.isEmpty {
                            Button("Load from provider") { Task { await loadModels() } }
                        }
                        ForEach(models, id: \.self) { model in
                            Button(model) { settings.systemTwoModel = model }
                        }
                    }
                    .fixedSize()
                }
                if settings.systemTwoProvider.needsAPIKey {
                    SecureField("API key", text: $apiKey)
                }
                if settings.systemTwoProvider == .copilot {
                    HStack {
                        TextField("Copilot CLI path", text: $settings.copilotPath)
                        Button("Detect") { Task { await detectCopilot() } }
                    }
                }
            } header: {
                Text("System Two")
            } footer: {
                Text(footer).font(.footnote).foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Button("Test System Two") { Task { await test() } }
                    if isBusy { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Save") { save() }
                        .keyboardShortcut(.defaultAction)
                }
                switch status {
                case .info(let text): Text(text).foregroundStyle(.secondary)
                case .error(let text): Text(text).foregroundStyle(.red)
                case nil: EmptyView()
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 540)
        .onAppear {
            NSApp.activate()
            apiKey = Keychain.secret(for: settings.systemTwoProvider.rawValue) ?? ""
        }
        .task {
            let supported = await SpeechListener.supportedLocales.map(\.identifier)
            voiceLocales = Set(supported + [settings.voiceLocale]).sorted()
        }
        .onChange(of: settings.systemTwoProvider) { _, provider in
            settings.systemTwoModel = provider.defaultModel
            apiKey = Keychain.secret(for: provider.rawValue) ?? ""
            models = []
            status = nil
        }
    }

    private var footer: LocalizedStringKey {
        let cloud: LocalizedStringKey =
            "Questions and unclear commands are sent to this provider. Multi-step tasks are always planned on this Mac."
        return settings.systemTwoProvider == .ollama ? "Everything stays on this Mac." : cloud
    }

    private func save() {
        settings.save()
        do {
            if settings.systemTwoProvider.needsAPIKey {
                try Keychain.setSecret(apiKey, for: settings.systemTwoProvider.rawValue)
            }
            controller.reload(settings)
            status = .info(String(localized: "Saved."))
        } catch {
            status = .error(error.localizedDescription)
        }
    }

    private func loadModels() async {
        await run {
            models = try await settings.systemTwo(apiKey: apiKey).client().listModels()
            return String(localized: "\(models.count) models available.")
        }
    }

    private func detectCopilot() async {
        await run {
            guard let url = await CopilotCLIClient.locate() else {
                throw ProviderError.commandFailed(String(localized: "Copilot CLI not found. Set its path in Settings."))
            }
            settings.copilotPath = url.path
            return url.path
        }
    }

    private func test() async {
        await run {
            let start = ContinuousClock.now
            let planner = ModelPlanner(client: try settings.systemTwo(apiKey: apiKey).client())
            let result = try await planner.plan("apri Safari e vai su apple.com", registry: controller.registry)
            let elapsed = ContinuousClock.now - start
            let seconds = elapsed.formatted(.units(allowed: [.seconds], fractionalPart: .show(length: 1)))
            let steps = result.steps.map(\.actionID).joined(separator: " → ")
            let outcome = steps.isEmpty ? result.answer ?? "-" : steps
            return String(localized: "OK in \(seconds): \(outcome)")
        }
    }

    private func run(_ work: () async throws -> String) async {
        isBusy = true
        defer { isBusy = false }
        do {
            status = .info(try await work())
        } catch {
            status = .error(error.localizedDescription)
        }
    }
}
