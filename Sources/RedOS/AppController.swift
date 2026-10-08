import AppKit
import RedOSActions
import RedOSCore

@MainActor
final class AppController {
    let permissions = PermissionCenter()
    let commandPanel = CommandPanelController(
        engine: CommandEngine(registry: ActionRegistry(SystemActions.all), audit: FileAuditLog())
    )
    private var hotKey: GlobalHotKey?

    func start() {
        hotKey = GlobalHotKey { [weak self] in self?.commandPanel.toggle() }
    }

    func revealAuditLog() {
        let url = FileAuditLog.defaultURL
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent().deletingLastPathComponent())
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = AppController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.start()
    }
}
