import RedOSCore
import SwiftUI

struct MenuContent: View {
    let permissions: PermissionCenter
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(verbatim: "RedOS \(AppInfo.version)")

        Divider()

        Button {
            openWindow(id: WindowID.permissions)
            NSApp.activate()
        } label: {
            if permissions.allGranted {
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
