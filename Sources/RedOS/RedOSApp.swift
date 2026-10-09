import RedOSCore
import SwiftUI

@main
struct RedOSApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    private var controller: AppController { appDelegate.controller }

    var body: some Scene {
        MenuBarExtra("RedOS", systemImage: "circle.hexagongrid.fill") {
            MenuContent(controller: controller)
        }

        Window("Permissions", id: WindowID.permissions) {
            PermissionsView(permissions: controller.permissions)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(controller.permissions.allGranted ? .suppressed : .presented)

        Window("Settings", id: WindowID.settings) {
            SettingsView(controller: controller)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
    }
}

enum WindowID {
    static let permissions = "permissions"
    static let settings = "settings"
}

enum AppInfo {
    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(short) (\(build))"
    }
}
