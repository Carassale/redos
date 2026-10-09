import RedOSCore
import SwiftUI

struct MenuContent: View {
    let controller: AppController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(verbatim: "RedOS \(AppInfo.version)")
        Text("System One: \(controller.systemOneDescription)")
        Text("System Two: \(controller.systemTwoDescription)")

        Divider()

        Button("Command…") {
            controller.commandPanel.show()
        }
        .keyboardShortcut(.space, modifiers: .option)

        Button("Show Audit Log") {
            controller.revealAuditLog()
        }

        Button("Settings…") {
            openWindow(id: WindowID.settings)
            NSApp.activate()
        }
        .keyboardShortcut(",")

        Divider()

        Button {
            openWindow(id: WindowID.permissions)
            NSApp.activate()
        } label: {
            if controller.permissions.allGranted {
                Label("Permissions…", systemImage: "checkmark.shield")
            } else {
                Label("Permissions required…", systemImage: "exclamationmark.shield")
            }
        }

        Divider()

        Button("Quit RedOS") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
