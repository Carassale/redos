import AppKit
import RedOSCore

struct OpenAppAction: Action {
    let id = "app.open"
    let summary = "Open or bring to front an application by name."
    let risk = RiskLevel.safe
    let parameters = [
        ActionParameter("name", description: "Real macOS application name (e.g. Safari for Apple's browser)")
    ]

    private static let searchDirectories = [
        "/Applications", "/Applications/Utilities", "/System/Applications",
        "/System/Applications/Utilities", NSHomeDirectory() + "/Applications",
    ]

    @MainActor
    func run(_ arguments: ActionArguments) async throws {
        let name = try arguments.string("name")
        let apps = Self.installedApplications()
        // Match both file names ("Calculator") and localized names ("Calcolatrice").
        let names = apps.map { $0.deletingPathExtension().lastPathComponent }
        let displayNames = apps.map { FileManager.default.displayName(atPath: $0.path) }
        guard let index = NameMatcher.bestMatch(for: name, in: names)
            ?? NameMatcher.bestMatch(for: name, in: displayNames)
        else { throw ActionError.failed(String(localized: "App not found: \(name)")) }

        try await NSWorkspace.shared.openApplication(
            at: apps[index], configuration: NSWorkspace.OpenConfiguration()
        )
    }

    private static func installedApplications() -> [URL] {
        searchDirectories.flatMap { directory in
            let url = URL(filePath: directory, directoryHint: .isDirectory)
            let contents = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            return (contents ?? []).filter { $0.pathExtension == "app" }
        }
    }
}

struct QuitAppAction: Action {
    let id = "app.quit"
    let summary = "Quit a running application by name."
    let risk = RiskLevel.moderate
    let parameters = [ActionParameter("name", description: "Application name, as written by the user")]

    @MainActor
    func run(_ arguments: ActionArguments) async throws {
        let name = try arguments.string("name")
        let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        guard let index = NameMatcher.bestMatch(for: name, in: running.map { $0.localizedName ?? "" }) else {
            throw ActionError.failed(String(localized: "App not running: \(name)"))
        }
        running[index].terminate()
    }
}
