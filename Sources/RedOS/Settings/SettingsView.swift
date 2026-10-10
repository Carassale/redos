import RedOSCore
import RedOSVoice
import SwiftUI

/// Tabbed settings; changes are applied on their own shortly after the last edit.
struct SettingsView: View {
    let controller: AppController
    @State private var settings: AppSettings
    @State private var apiKey: String
    @State private var applied: Draft

    struct Draft: Equatable {
        var settings: AppSettings
        var apiKey: String
    }

    init(controller: AppController) {
        self.controller = controller
        let settings = AppSettings()
        let apiKey = Keychain.secret(for: settings.systemTwoProvider.rawValue) ?? ""
        _settings = State(initialValue: settings)
        _apiKey = State(initialValue: apiKey)
        _applied = State(initialValue: Draft(settings: settings, apiKey: apiKey))
    }

    private var draft: Draft { Draft(settings: settings, apiKey: apiKey) }

    @State private var pane: SettingsPane? = SettingsView.needsSetup ? .setup : .general

    /// First launch, or a permission is still missing.
    @MainActor static var needsSetup: Bool {
        !UserDefaults.standard.bool(forKey: SetupView.seenKey) || !PermissionCenter().allGranted
    }

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: $pane) { pane in
                Label {
                    Text(pane.title)
                } icon: {
                    Image(systemName: pane.symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(pane.color.gradient, in: .rect(cornerRadius: 6))
                }
                .tag(pane)
            }
            .navigationSplitViewColumnWidth(200)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            detail(pane ?? .general)
                .navigationTitle(Text((pane ?? .general).title))
        }
        .frame(width: 800, height: 580)
        .onAppear { NSApp.activate() }
        .onChange(of: settings.systemTwoProvider) { _, provider in
            settings.systemTwoModel = provider.defaultModel
            apiKey = Keychain.secret(for: provider.rawValue) ?? ""
        }
        .task(id: draft) {
            guard draft != applied else { return }
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            apply()
        }
        .onDisappear {
            if draft != applied { apply() }
        }
    }

    @ViewBuilder
    private func detail(_ pane: SettingsPane) -> some View {
        switch pane {
        case .setup:
            SetupView(controller: controller, settings: $settings, apiKey: $apiKey, pane: $pane)
        case .general:
            GeneralSettingsView(controller: controller, settings: $settings)
        case .models:
            ModelsSettingsView(controller: controller, settings: $settings, apiKey: $apiKey)
        case .privacy:
            CloudSettingsView(controller: controller, settings: $settings)
        case .integrations:
            IntegrationsSettingsView(controller: controller, settings: $settings)
        case .routines:
            Form {
                RoutinesSection(store: controller.routines) { controller.commandPanel.runRoutine(named: $0) }
            }
            .formStyle(.grouped)
        case .memory:
            Form { MemorySection(store: controller.memory) }.formStyle(.grouped)
        }
    }

    private func apply() {
        settings.save()
        let account = settings.systemTwoProvider.rawValue
        if settings.systemTwoProvider.needsAPIKey, apiKey != (Keychain.secret(for: account) ?? "") {
            try? Keychain.setSecret(apiKey.isEmpty ? nil : apiKey, for: account)
        }
        controller.reload(settings)
        applied = draft
    }
}

enum SettingsPane: String, CaseIterable, Identifiable {
    case setup, general, models, privacy, integrations, routines, memory

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .setup: "Setup"
        case .general: "General"
        case .models: "Models"
        case .privacy: "Privacy & Cloud"
        case .integrations: "Integrations"
        case .routines: "Routines"
        case .memory: "Memory"
        }
    }

    var symbol: String {
        switch self {
        case .setup: "checklist"
        case .general: "gearshape.fill"
        case .models: "cpu.fill"
        case .privacy: "lock.shield.fill"
        case .integrations: "puzzlepiece.extension.fill"
        case .routines: "repeat"
        case .memory: "brain.fill"
        }
    }

    var color: Color {
        switch self {
        case .setup: .green
        case .general: .gray
        case .models: .purple
        case .privacy: .blue
        case .integrations: .indigo
        case .routines: .orange
        case .memory: .pink
        }
    }
}

struct GeneralSettingsView: View {
    let controller: AppController
    @Binding var settings: AppSettings
    @State private var voiceLocales: [String] = []
    @State private var checksForUpdates = true
    @State private var receivesBetas = false

    var body: some View {
        Form {
            Section {
                Picker("Priority", selection: $settings.prefersAccuracy) {
                    Text("Accuracy").tag(true)
                    Text("Speed").tag(false)
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Behavior")
            } footer: {
                Text(priorityFooter).font(.footnote).foregroundStyle(.secondary)
            }

            Section {
                Picker("Language", selection: $settings.voiceLocale) {
                    ForEach(voiceLocales, id: \.self) { identifier in
                        Text(Locale.current.localizedString(forIdentifier: identifier) ?? identifier).tag(identifier)
                    }
                }
                Toggle("Speak answers", isOn: $settings.speaksAnswers)
                Toggle("Keep listening after answering", isOn: $settings.keepsListening)
                    .help("After a spoken request, reply or interrupt RedOS without saying “Hey Red” again.")
                Toggle("Listen for “Hey Red”", isOn: $settings.wakeWordEnabled)
                if settings.wakeWordEnabled {
                    LabeledContent("Sensitivity") {
                        // Higher sensitivity = lower score threshold.
                        Slider(
                            value: Binding(
                                get: { 1 - settings.wakeWordThreshold },
                                set: { settings.wakeWordThreshold = 1 - $0 }
                            ),
                            in: 0.1...0.8
                        ) {
                            EmptyView()
                        } minimumValueLabel: {
                            Image(systemName: "speaker.wave.1")
                        } maximumValueLabel: {
                            Image(systemName: "speaker.wave.3")
                        }
                    }
                    if let error = controller.wakeWordError {
                        Text(verbatim: error).foregroundStyle(.red)
                    }
                }
            } header: {
                Text("Voice")
            } footer: {
                Text(settings.wakeWordEnabled
                    ? Self.wakeWordFooter
                    : "Hold ⌃⌥Space and speak; release to send. Speech is recognized on this Mac.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            // Applied immediately, like Sparkle's own preferences.
            Section("Updates") {
                Toggle("Check for updates automatically", isOn: $checksForUpdates)
                    .onChange(of: checksForUpdates) { _, value in controller.updater.automaticallyChecks = value }
                Toggle("Include beta versions", isOn: $receivesBetas)
                    .onChange(of: receivesBetas) { _, value in controller.updater.receivesBetas = value }
                LabeledContent("Version") {
                    HStack {
                        Text(verbatim: AppInfo.version).foregroundStyle(.secondary)
                        Button("Check Now") { controller.updater.checkForUpdates() }
                            .disabled(!controller.updater.canCheckForUpdates)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            checksForUpdates = controller.updater.automaticallyChecks
            receivesBetas = controller.updater.receivesBetas
        }
        .task {
            let supported = await SpeechListener.supportedLocales.map(\.identifier)
            voiceLocales = Set(supported + [settings.voiceLocale]).sorted()
        }
    }

    private static let wakeWordFooter: LocalizedStringKey = """
        Say “Hey Red” and then the command: it is sent when you pause. \
        The wake word is detected on this Mac; the microphone stays on.
        """

    private var priorityFooter: LocalizedStringKey {
        guard settings.systemTwoProvider != .ollama else { return "Everything stays on this Mac." }
        return settings.prefersAccuracy
            ? "Accuracy: questions, multi-step tasks and screen tasks go to this provider; simple commands stay local."
            : "Speed: questions go to this provider; multi-step and screen tasks are planned on this Mac."
    }
}

struct CloudSettingsView: View {
    let controller: AppController
    @Binding var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Toggle("Offline only (use the local model)", isOn: $settings.offlineOnly)
            } footer: {
                Text(settings.systemTwoProvider == .ollama
                    ? "The assistant runs on this Mac: nothing is sent to the cloud."
                    : "Commands, questions, screen content and remembered facts go to the assistant's provider.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if settings.systemTwoProvider != .ollama, !settings.offlineOnly {
                Section {
                    Stepper(value: $settings.dailyCloudLimit, in: 0...1000, step: 10) {
                        Text(settings.dailyCloudLimit == 0
                            ? "Daily cloud limit: none"
                            : "Daily cloud limit: \(settings.dailyCloudLimit) requests")
                    }
                    UsageLabel(store: controller.usage)
                } header: {
                    Text("Usage")
                } footer: {
                    Text("Beyond the limit the assistant uses the local model.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section("Activity log") {
                Button("Show Audit Log") { controller.revealAuditLog() }
            }
        }
        .formStyle(.grouped)
    }
}
