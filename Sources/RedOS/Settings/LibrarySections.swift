import RedOSCore
import SwiftUI

struct RoutinesSection: View {
    let store: RoutineStore
    let onRun: (String) -> Void
    @State private var routines: [Routine] = []

    var body: some View {
        Section {
            if routines.isEmpty {
                Text("Say “crea la routine buongiorno: apri Mail e Calendario” to create one.")
                    .foregroundStyle(.secondary)
            }
            ForEach(routines) { routine in
                HStack {
                    VStack(alignment: .leading) {
                        Text(verbatim: routine.name)
                        Text(verbatim: details(routine)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if routine.schedule != nil || routine.launchApp != nil {
                        Button("Remove Triggers") { change(routine) { $0.schedule = nil; $0.launchApp = nil } }
                    }
                    Button("Run") { onRun(routine.name) }
                    Button("Delete", role: .destructive) {
                        Task {
                            _ = try? await store.remove(named: routine.name)
                            await reload()
                        }
                    }
                }
                .controlSize(.small)
            }
        } header: {
            Text("Routines")
        } footer: {
            Text("“programma la routine X alle 9” or “avvia la routine X quando apro Xcode” add triggers.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .task { await reload() }
    }

    private func details(_ routine: Routine) -> String {
        var parts = [routine.steps.map(CommandEngine.describe).joined(separator: " → ")]
        if let schedule = routine.schedule {
            parts.append("⏰ \(schedule.time)" + (schedule.weekdaysOnly ? " (Mon–Fri)" : ""))
        }
        if let app = routine.launchApp { parts.append("▶︎ \(app)") }
        return parts.joined(separator: " · ")
    }

    private func change(_ routine: Routine, _ edit: @escaping @Sendable (inout Routine) -> Void) {
        Task {
            _ = try? await store.update(named: routine.name, edit)
            await reload()
        }
    }

    private func reload() async {
        routines = await store.all()
    }
}

struct MemorySection: View {
    let store: MemoryStore
    @State private var facts: [String] = []

    var body: some View {
        Section {
            if facts.isEmpty {
                Text("Say “ricorda che il mio editor è Visual Studio Code”.").foregroundStyle(.secondary)
            }
            ForEach(facts, id: \.self) { fact in
                HStack {
                    Text(verbatim: fact)
                    Spacer()
                    Button("Forget", role: .destructive) {
                        Task {
                            try? await store.remove(fact)
                            facts = await store.facts()
                        }
                    }
                    .controlSize(.small)
                }
            }
        } header: {
            Text("Memory")
        } footer: {
            Text("Remembered facts are sent to System Two as context, including cloud providers.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .task { facts = await store.facts() }
    }
}

struct UsageLabel: View {
    let store: UsageStore
    @State private var today = UsageRecord()
    @State private var month = UsageRecord()

    var body: some View {
        LabeledContent("Cloud usage") {
            Text("Today \(today.requests) requests (~\(today.tokens) tokens), month \(month.requests)")
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .task {
            today = await store.today()
            month = await store.month()
        }
    }
}
