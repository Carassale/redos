import RedOSCore
import SwiftUI

@main
struct RedOSApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    private var controller: AppController { appDelegate.controller }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(controller: controller)
        } label: {
            // Filled circle: an answer arrived while the panel was closed.
            Image(systemName: controller.hasUnseenResult ? "circle.hexagongrid.circle.fill" : "circle.hexagongrid.fill")
        }

        Window("Permissions", id: WindowID.permissions) {
            PermissionsView(permissions: controller.permissions)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)

        // Opens on Setup at first launch or while a permission is missing.
        Window("Settings", id: WindowID.settings) {
            SettingsView(controller: controller)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(SettingsView.needsSetup ? .presented : .suppressed)
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
