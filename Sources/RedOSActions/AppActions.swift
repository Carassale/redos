import AppKit
import RedOSCore

struct OpenAppAction: Action {
    let id = "app.open"
    let summary = "Open or bring to front an application by name."
    let risk = RiskLevel.safe
    let parameters = [
        ActionParameter("name", description: "Real macOS application name (e.g. Safari for Apple's browser)")
    ]

    @MainActor
    func run(_ arguments: ActionArguments) async throws {
        let name = try arguments.string("name")
        try await NSWorkspace.shared.openApplication(
            at: try InstalledApps.url(named: name), configuration: NSWorkspace.OpenConfiguration()
        )
    }
}

struct OpenURLAction: Action {
    let id = "url.open"
    let summary = "Open a website or web address (e.g. google.com) in the browser, optionally in a given browser app."
    let risk = RiskLevel.safe
    let parameters = [
        ActionParameter("url", .webAddress, description: "Web address, e.g. google.com or https://github.com"),
        ActionParameter("app", required: false, description: "Browser application name, only if stated"),
    ]

    @MainActor
    func run(_ arguments: ActionArguments) async throws {
        let address = try arguments.string("url")
        guard let url = WebAddress.url(from: address) else { throw ActionError.invalidArgument("url", address) }
        guard let app = arguments["app"], !app.isEmpty else {
            NSWorkspace.shared.open(url)
            return
        }
        try await NSWorkspace.shared.open(
            [url], withApplicationAt: try InstalledApps.url(named: app), configuration: NSWorkspace.OpenConfiguration()
        )
    }
}

enum InstalledApps {
    private static let searchDirectories = [
        "/Applications", "/Applications/Utilities", "/System/Applications",
        "/System/Applications/Utilities", NSHomeDirectory() + "/Applications",
    ]

    static func url(named name: String) throws -> URL {
        let apps = searchDirectories.flatMap { directory in
            let url = URL(filePath: directory, directoryHint: .isDirectory)
            let contents = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            return (contents ?? []).filter { $0.pathExtension == "app" }
        }
        // Match both file names ("Calculator") and localized names ("Calcolatrice").
        let names = apps.map { $0.deletingPathExtension().lastPathComponent }
        let displayNames = apps.map { FileManager.default.displayName(atPath: $0.path) }
        guard let index = NameMatcher.bestMatch(for: name, in: names)
            ?? NameMatcher.bestMatch(for: name, in: displayNames)
        else { throw ActionError.failed(String(localized: "App not found: \(name)")) }
        return apps[index]
    }
}

struct QuitAppAction: Action {
    let id = "app.quit"
    let summary = "Quit, close or turn off a running application by name. Not the computer itself."
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
