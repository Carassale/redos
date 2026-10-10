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
        if let url = match(name, in: catalog) { return url }
        // Installed since the catalog was built.
        catalog = buildCatalog()
        guard let url = match(name, in: catalog) else {
            throw ActionError.failed(String(localized: "App not found: \(name)"))
        }
        return url
    }

    /// Every name an app answers to: file name ("Calculator"), display name and the Italian and English
    /// names from its InfoPlist ("Calcolatrice"), whatever the language of the Mac.
    private struct Entry {
        let url: URL
        let names: [String]
    }

    nonisolated(unsafe) private static var catalog = buildCatalog()

    private static func match(_ name: String, in entries: [Entry]) -> URL? {
        let all = entries.flatMap { entry in entry.names.map { (entry.url, $0) } }
        return NameMatcher.bestMatch(for: name, in: all.map(\.1)).map { all[$0].0 }
    }

    private static func buildCatalog() -> [Entry] {
        let apps = searchDirectories.flatMap { directory in
            let url = URL(filePath: directory, directoryHint: .isDirectory)
            let contents = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            return (contents ?? []).filter { $0.pathExtension == "app" }
        }
        return apps.map { app in
            let fileName = app.deletingPathExtension().lastPathComponent
            let names = [fileName, FileManager.default.displayName(atPath: app.path)]
            return Entry(url: app, names: names + localizedNames(of: app))
        }
    }

    private static func localizedNames(of app: URL) -> [String] {
        let resources = app.appending(path: "Contents/Resources")
        var names: [String] = []
        if let data = try? Data(contentsOf: resources.appending(path: "InfoPlist.loctable")),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
           let table = plist as? [String: [String: Any]] {
            for language in ["it", "en"] {
                names += ["CFBundleDisplayName", "CFBundleName"].compactMap { table[language]?[$0] as? String }
            }
        }
        for language in ["it", "en"] {
            let strings = resources.appending(path: "\(language).lproj/InfoPlist.strings")
            if let table = NSDictionary(contentsOf: strings) as? [String: String] {
                names += ["CFBundleDisplayName", "CFBundleName"].compactMap { table[$0] }
            }
        }
        return names
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
