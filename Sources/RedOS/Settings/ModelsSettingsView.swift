import RedOSCore
import SwiftUI

enum SettingsStatus: Equatable {
    case info(String)
    case error(String)
}

/// The assistant (System Two) and the local Ollama models; model lists load on their own.
struct ModelsSettingsView: View {
    let controller: AppController
    @Binding var settings: AppSettings
    @Binding var apiKey: String
    /// nil while Ollama is not reachable.
    @State private var installed: [String]?
    @State private var remote: [String] = []
    @State private var isLoadingRemote = false
    @State private var downloads: [String: Double] = [:]
    @State private var status: SettingsStatus?
    @State private var isTesting = false

    private let ollama = OllamaClient(model: "")

    var body: some View {
        Form {
            assistantSection
            localSection
            Section {
                LabeledContent("Minimum probability to act") {
                    HStack {
                        Slider(value: $settings.threshold, in: 0.3...0.95, step: 0.05)
                        Text(settings.threshold, format: .number.precision(.fractionLength(2))).monospacedDigit()
                    }
                }
            } header: {
                Text("Advanced")
            } footer: {
                Text(Self.thresholdFooter).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { await refreshInstalled() }
        .task(id: "\(settings.systemTwoProvider.rawValue)|\(apiKey.isEmpty)|\(settings.copilotPath)") {
            await loadRemote()
        }
    }

    private var assistantSection: some View {
        Section {
            Picker("Provider", selection: $settings.systemTwoProvider) {
                ForEach(SystemTwoProvider.allCases) { Text($0.displayName).tag($0) }
            }
            if settings.systemTwoProvider.needsAPIKey {
                SecureField("API key", text: $apiKey)
            }
            if settings.systemTwoProvider == .copilot {
                LabeledContent("Copilot CLI") {
                    HStack {
                        TextField("Copilot CLI", text: $settings.copilotPath).labelsHidden()
                        Button("Detect") { Task { await detectCopilot() } }
                    }
                }
            }
            modelPicker(
                "Model", selection: $settings.systemTwoModel,
                options: settings.systemTwoProvider == .ollama ? installed ?? [] : remote,
                recommended: settings.systemTwoProvider.defaultModel, isLoading: isLoadingRemote
            )
            HStack {
                Button("Test") { Task { await test() } }.disabled(isTesting)
                if isTesting { ProgressView().controlSize(.small) }
                switch status {
                case .info(let text): Text(verbatim: text).foregroundStyle(.secondary).lineLimit(2)
                case .error(let text): Text(verbatim: text).foregroundStyle(.red).lineLimit(2)
                case nil: EmptyView()
                }
            }
        } header: {
            Text("Assistant (System Two)")
        } footer: {
            Text("Answers questions, plans multi-step tasks, reads the screen and draws diagrams.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var localSection: some View {
        Section {
            LabeledContent("Ollama") {
                HStack {
                    if let installed {
                        Text("Running · \(installed.count) models").foregroundStyle(.secondary)
                    } else {
                        Text("Not running").foregroundStyle(.red)
                    }
                    Button { Task { await refreshInstalled() } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless)
                        .help("Refresh")
                }
            }
            modelPicker(
                "Commands", selection: $settings.systemOneModel, options: installed ?? [],
                recommended: AppSettings.defaultSystemOneModel
            )
            modelPicker(
                "Parameters", selection: $settings.extractionModel, options: installed ?? [],
                recommended: AppSettings.defaultExtractionModel
            )
            ForEach(missing, id: \.self) { model in
                LabeledContent {
                    if let fraction = downloads[model] {
                        ProgressView(value: fraction).frame(width: 140)
                    } else {
                        Button("Download") { Task { await download(model) } }
                    }
                } label: {
                    Label("\(model) is not installed", systemImage: "exclamationmark.triangle")
                }
            }
        } header: {
            Text("On this Mac (Ollama)")
        } footer: {
            Text(installed == nil ? "Start Ollama with: brew services start ollama" : Self.localFooter)
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private static let localFooter: LocalizedStringKey = """
        Commands: understands simple commands in about a second. \
        Parameters: a smaller model that extracts names, numbers and text.
        """

    private static let thresholdFooter: LocalizedStringKey = """
        Lower: acts on its own more often. Higher: asks the assistant more often. \
        With Accuracy priority at least 0.85.
        """

    /// A menu of the available models, or a text field when the list cannot be loaded.
    @ViewBuilder
    private func modelPicker(
        _ title: LocalizedStringKey, selection: Binding<String>, options: [String], recommended: String,
        isLoading: Bool = false
    ) -> some View {
        if options.isEmpty {
            LabeledContent(title) {
                HStack {
                    TextField(title, text: selection).labelsHidden()
                    if isLoading { ProgressView().controlSize(.small) }
                }
            }
        } else {
            let current = selection.wrappedValue
            let choices = current.isEmpty || options.contains(current) ? options : [current] + options
            Picker(title, selection: selection) {
                ForEach(choices, id: \.self) { model in
                    Text(model == recommended ? "\(model) (recommended)" : "\(model)").tag(model)
                }
            }
        }
    }

    /// Configured local models that Ollama does not have yet.
    private var missing: [String] {
        guard let installed else { return [] }
        let wanted = [settings.systemOneModel, settings.extractionModel]
            + (settings.systemTwoProvider == .ollama ? [settings.systemTwoModel] : [])
        var seen = Set<String>()
        return wanted.filter { model in
            !model.isEmpty && !installed.contains(model) && !installed.contains("\(model):latest")
                && seen.insert(model).inserted
        }
    }

    private func refreshInstalled() async {
        installed = try? await ollama.listModels()
    }

    private func loadRemote() async {
        remote = []
        let provider = settings.systemTwoProvider
        guard provider != .ollama else { return }
        if provider == .copilot, settings.copilotPath.isEmpty {
            await detectCopilot()
            return
        }
        if provider.needsAPIKey, apiKey.isEmpty { return }
        isLoadingRemote = true
        defer { isLoadingRemote = false }
        remote = (try? await settings.systemTwo(apiKey: apiKey).client().listModels()) ?? []
    }

    private func download(_ model: String) async {
        downloads[model] = 0
        defer { downloads[model] = nil }
        let (updates, feed) = AsyncStream<Double>.makeStream()
        let ollama = ollama
        let pull = Task {
            defer { feed.finish() }
            try await ollama.pull(model) { feed.yield($0) }
        }
        for await fraction in updates {
            downloads[model] = fraction
        }
        do {
            try await pull.value
            await refreshInstalled()
        } catch {
            status = .error(error.localizedDescription)
        }
    }

    private func detectCopilot() async {
        if let url = await CopilotCLIClient.locate() {
            settings.copilotPath = url.path
        } else {
            status = .error(String(localized: "Copilot CLI not found. Set its path in Settings."))
        }
    }

    private func test() async {
        isTesting = true
        defer { isTesting = false }
        status = nil
        do {
            let start = ContinuousClock.now
            let planner = ModelPlanner(client: try settings.systemTwo(apiKey: apiKey).client())
            let result = try await planner.plan("apri Safari e vai su apple.com", registry: controller.registry)
            let seconds = (ContinuousClock.now - start)
                .formatted(.units(allowed: [.seconds], fractionalPart: .show(length: 1)))
            let steps = result.steps.map(\.actionID).joined(separator: " → ")
            status = .info(String(localized: "OK in \(seconds): \(steps.isEmpty ? result.answer ?? "-" : steps)"))
        } catch {
            status = .error(error.localizedDescription)
        }
    }
}
