import RedOSCore
import SwiftUI

/// Who makes the fast decisions: the local model or a Jev-compatible service (Codiv's OpenJev by default).
struct DecisionsSection: View {
    let controller: AppController
    @Binding var settings: AppSettings
    @State private var key = Keychain.secret(for: DecisionProvider.keyAccount) ?? ""
    @State private var status: SettingsStatus?
    @State private var isTesting = false

    static let codivSignUp = URL(string: "https://codiv.ai")!

    var body: some View {
        Section {
            Picker("Decisions", selection: $settings.decisionProvider) {
                Text("On this Mac (Ollama)").tag(DecisionProvider.local)
                Text("Codiv (OpenJev, cloud)").tag(DecisionProvider.codiv)
                Text("Custom Jev server").tag(DecisionProvider.custom)
            }
            if settings.decisionProvider == .custom {
                TextField("Server URL", text: $settings.jevURL, prompt: Text(verbatim: "http://127.0.0.1:8080"))
            }
            if settings.decisionProvider != .local {
                SecureField("API key", text: $key)
                if settings.decisionProvider == .codiv {
                    Link("Get a free key (100M tokens)", destination: Self.codivSignUp)
                }
                TextField("Model", text: $settings.jevModel)
                HStack {
                    Button("Test") { Task { await test() } }.disabled(isTesting)
                    if isTesting { ProgressView().controlSize(.small) }
                    switch status {
                    case .info(let text): Text(verbatim: text).foregroundStyle(.secondary).lineLimit(2)
                    case .error(let text): Text(verbatim: text).foregroundStyle(.red).lineLimit(2)
                    case nil: EmptyView()
                    }
                }
            }
        } header: {
            Text("Fast decisions (System One)")
        } footer: {
            Text(settings.decisionProvider == .local ? Self.localFooter : Self.jevFooter)
                .font(.footnote).foregroundStyle(.secondary)
        }
        .task(id: key) {
            guard key != (Keychain.secret(for: DecisionProvider.keyAccount) ?? "") else { return }
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            try? Keychain.setSecret(key.isEmpty ? nil : key, for: DecisionProvider.keyAccount)
            controller.reload(settings)
        }
    }

    /// One real decision, timed: the request kind and the action for a sample command.
    private func test() async {
        isTesting = true
        defer { isTesting = false }
        status = nil
        try? Keychain.setSecret(key.isEmpty ? nil : key, for: DecisionProvider.keyAccount)
        guard let jev = controller.jevClient(settings) else {
            status = .error(String(localized: "Enter the server and the API key."))
            return
        }
        let router = JevIntentRouter(registry: controller.registry, jev: jev, extractor: nil)
        do {
            let start = ContinuousClock.now
            let answers = try await jev.decide(state: "User request: apri Safari", questions: router.questions)
            let seconds = (ContinuousClock.now - start)
                .formatted(.units(allowed: [.seconds], fractionalPart: .show(length: 2)))
            let kind = answers["kind"]?.choice ?? "?"
            let action = answers["action"].map { "\($0.choice ?? "?") \(Int($0.probability * 100))%" } ?? "?"
            status = .info(String(localized: "OK in \(seconds): \(kind), \(action)"))
        } catch {
            status = .error(error.localizedDescription)
        }
    }

    private static let localFooter: LocalizedStringKey = """
        The local model chooses the action; questions and screen tasks are sorted by System Two. Works offline.
        """

    private static let jevFooter: LocalizedStringKey = """
        One request decides the kind of request and the action in a fraction of a second; the command text is \
        sent to the service. Without network or with Offline only, the local model takes over.
        """
}
