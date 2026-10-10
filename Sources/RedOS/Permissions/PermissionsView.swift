import RedOSCore
import SwiftUI

struct PermissionsView: View {
    let permissions: PermissionCenter

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("RedOS needs these permissions to control your Mac.")
                .font(.headline)

            ForEach(Permission.allCases) { permission in
                PermissionRow(
                    permission: permission,
                    status: permissions.status(of: permission),
                    onRequest: { Task { await permissions.request(permission) } }
                )
            }

            Text("Screen Recording changes take effect after restarting RedOS.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 480)
        .onAppear { NSApp.activate() }
        .task {
            // Accessibility and Screen Recording have no change notifications.
            while !Task.isCancelled {
                permissions.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}

struct PermissionRow: View {
    let permission: Permission
    let status: PermissionStatus
    let onRequest: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: permission.symbol)
                .font(.title2)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(permission.title).font(.body.weight(.semibold))
                Text(permission.purpose).font(.callout).foregroundStyle(.secondary)
            }

            Spacer()

            if status == .granted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.title2)
            } else {
                Button("Grant", action: onRequest)
                Button("Open Settings") {
                    NSWorkspace.shared.open(permission.settingsURL)
                }
            }
        }
    }
}

extension Permission {
    var title: LocalizedStringKey {
        switch self {
        case .accessibility: "Accessibility"
        case .microphone: "Microphone"
        case .screenRecording: "Screen Recording"
        }
    }

    var purpose: LocalizedStringKey {
        switch self {
        case .accessibility: "Control mouse, keyboard and app interfaces."
        case .microphone: "Listen for the wake word and voice commands."
        case .screenRecording: "Read the screen when an action needs visual context."
        }
    }

    var symbol: String {
        switch self {
        case .accessibility: "accessibility"
        case .microphone: "mic"
        case .screenRecording: "rectangle.dashed.badge.record"
        }
    }
}
