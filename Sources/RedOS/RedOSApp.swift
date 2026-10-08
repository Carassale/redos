import RedOSCore
import SwiftUI

@main
struct RedOSApp: App {
    @State private var permissions = PermissionCenter()

    var body: some Scene {
        MenuBarExtra("RedOS", systemImage: "circle.hexagongrid.fill") {
            MenuContent(permissions: permissions)
        }

        Window("Permissions", id: WindowID.permissions) {
            PermissionsView(permissions: permissions)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(permissions.allGranted ? .suppressed : .presented)
    }
}

enum WindowID {
    static let permissions = "permissions"
}

enum AppInfo {
    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(short) (\(build))"
    }
}
