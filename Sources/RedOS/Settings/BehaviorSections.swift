import RedOSCore
import SwiftUI

/// How RedOS talks.
struct PersonaSection: View {
    @Binding var settings: AppSettings

    var body: some View {
        Section {
            Picker("Persona", selection: $settings.persona) {
                ForEach(Persona.allCases) { persona in
                    Text(Self.title(persona)).tag(persona)
                }
            }
            if settings.persona == .custom {
                TextField("Describe how RedOS should talk", text: $settings.customPersona, axis: .vertical)
                    .lineLimit(2...4)
            }
        } header: {
            Text("Persona")
        } footer: {
            Text("Used by the assistant in answers and plans. Rules said by voice (“d'ora in poi…”) are in Memory.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private static func title(_ persona: Persona) -> LocalizedStringKey {
        switch persona {
        case .neutral: "Neutral"
        case .butler: "Butler (Jarvis)"
        case .friendly: "Friendly"
        case .concise: "Concise"
        case .custom: "Custom"
        }
    }
}

/// RedOS speaking first.
struct ProactivitySection: View {
    @Binding var settings: AppSettings

    var body: some View {
        Section {
            Toggle("Speak up on its own", isOn: $settings.isProactive)
            Toggle("Morning briefing", isOn: $settings.morningBriefing)
                .disabled(!settings.isProactive)
        } header: {
            Text("Proactivity")
        } footer: {
            Text("Meetings, low battery, call apps, a morning briefing. Jev decides: speak, notify or stay quiet.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

/// Standing rules said by voice.
struct BehaviorsSection: View {
    let store: BehaviorStore
    @State private var rules: [Behavior] = []

    var body: some View {
        Section {
            if rules.isEmpty {
                Text("Say “d'ora in poi rispondimi in breve” or “quando uso Slack, scrivi in inglese”.")
                    .foregroundStyle(.secondary)
            }
            ForEach(rules) { rule in
                HStack {
                    VStack(alignment: .leading) {
                        Text(verbatim: rule.rule)
                        if let app = rule.app {
                            Text("Only in \(app)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Remove", role: .destructive) {
                        Task {
                            _ = try? await store.remove(matching: rule.id)
                            rules = await store.all()
                        }
                    }
                    .controlSize(.small)
                }
            }
        } header: {
            Text("Rules")
        } footer: {
            Text("Sent to the assistant with every request. Say “quali regole hai?” to hear them.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .task { rules = await store.all() }
    }
}
