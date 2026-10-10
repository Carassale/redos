import AppKit
import RedOSCore

struct ShortcutAction: ReportingAction {
    let id = "shortcut.run"
    let summary = "Run one of the user's Shortcuts (Shortcuts app) by name, e.g. a Focus, Home or "
        + "automation shortcut, optionally with input text."
    let risk = RiskLevel.moderate
    let parameters = [
        ActionParameter("name", description: "The shortcut's name as the user says it"),
        ActionParameter(
            "input", required: false, sensitive: true, description: "Text passed to the shortcut, only if stated"
        ),
    ]

    @MainActor
    func report(_ arguments: ActionArguments) async throws -> String {
        let requested = try arguments.string("name")
        let list = try await CommandLineTool.run("/usr/bin/shortcuts", ["list"])
        let names = list.split(separator: "\n").map(String.init)
        guard let index = NameMatcher.bestMatch(for: requested, in: names) else {
            throw ActionError.failed(String(localized: "Shortcut not found: \(requested)"))
        }
        var options = ["run", names[index]]
        let directory = FileManager.default.temporaryDirectory.appending(path: "redos-shortcut-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        if let input = arguments["input"], !input.isEmpty {
            let file = directory.appending(path: "input.txt")
            try input.write(to: file, atomically: true, encoding: .utf8)
            options += ["--input-path", file.path]
        }
        let output = directory.appending(path: "output")
        _ = try await CommandLineTool.run("/usr/bin/shortcuts", options + ["--output-path", output.path])
        let result = (try? String(contentsOf: output, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "Ran “\(names[index])”.")
    }
}

struct WindowAction: Action {
    let id = "window.arrange"
    let summary = "Move or resize the front window: left or right half, top or bottom half, maximize, "
        + "center, minimize or full screen."
    let risk = RiskLevel.safe
    let parameters = [
        ActionParameter(
            "position", .oneOf(["left", "right", "top", "bottom", "maximize", "center", "minimize", "fullscreen"]),
            description: "Where the window goes"
        ),
    ]
    let requiredPermissions = [Permission.accessibility]

    @MainActor
    func run(_ arguments: ActionArguments) async throws {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            throw ActionError.failed(String(localized: "No app is in front."))
        }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        guard let window = root.element(kAXFocusedWindowAttribute) ?? root.element(kAXMainWindowAttribute),
              let frame = window.frame
        else { throw ActionError.failed(String(localized: "No window to arrange.")) }
        switch arguments["position"] {
        case "minimize":
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
            return
        case "fullscreen":
            AXUIElementSetAttributeValue(window, "AXFullScreen" as CFString, kCFBooleanTrue)
            return
        default:
            break
        }
        let area = Self.visibleArea(around: frame)
        var origin = Self.target(arguments["position"], in: area, size: frame.size).origin
        var size = Self.target(arguments["position"], in: area, size: frame.size).size
        if let position = AXValueCreate(.cgPoint, &origin) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position)
        }
        if let dimensions = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, dimensions)
        }
    }

    private static func target(_ position: String?, in area: CGRect, size: CGSize) -> CGRect {
        switch position {
        case "left": CGRect(x: area.minX, y: area.minY, width: area.width / 2, height: area.height)
        case "right": CGRect(x: area.midX, y: area.minY, width: area.width / 2, height: area.height)
        case "top": CGRect(x: area.minX, y: area.minY, width: area.width, height: area.height / 2)
        case "bottom": CGRect(x: area.minX, y: area.midY, width: area.width, height: area.height / 2)
        case "center":
            CGRect(origin: CGPoint(x: area.midX - size.width / 2, y: area.midY - size.height / 2), size: size)
        default: area
        }
    }

    /// The usable area (no menu bar, no Dock) of the screen holding `frame`, in Accessibility coordinates
    /// (origin at the top left of the main screen).
    private static func visibleArea(around frame: CGRect) -> CGRect {
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        let center = CGPoint(x: frame.midX, y: mainHeight - frame.midY)
        let screen = NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        return CGRect(x: visible.minX, y: mainHeight - visible.maxY, width: visible.width, height: visible.height)
    }
}

struct FindFileAction: ReportingAction {
    let id = "file.find"
    let summary = "Search the user's files with Spotlight by name or content and list where they are."
    let risk = RiskLevel.safe
    let parameters = [ActionParameter("query", description: "What to look for, e.g. invoice September")]

    @MainActor
    func report(_ arguments: ActionArguments) async throws -> String {
        let files = try await Spotlight.search(try arguments.string("query"))
        guard !files.isEmpty else { return String(localized: "No files found.") }
        let home = URL.homeDirectory.path
        return files.prefix(10).map { $0.path.replacingOccurrences(of: home, with: "~") }.joined(separator: "\n")
    }
}

struct OpenFileAction: Action {
    let id = "file.open"
    let summary = "Find a document, folder or file by name with Spotlight and open it."
    let risk = RiskLevel.safe
    let parameters = [ActionParameter("query", description: "The file's name or words in it")]

    @MainActor
    func run(_ arguments: ActionArguments) async throws {
        let query = try arguments.string("query")
        guard let file = try await Spotlight.search(query).first else {
            throw ActionError.failed(String(localized: "File not found: \(query)"))
        }
        NSWorkspace.shared.open(file)
    }
}

struct MailDraftAction: Action {
    let id = "mail.draft"
    let summary = "Open a new email draft in Mail with recipient, subject and text, for the user to send."
    let risk = RiskLevel.moderate
    let parameters = [
        ActionParameter("to", required: false, description: "Recipient email address or name, only if stated"),
        ActionParameter("subject", required: false, description: "Subject, only if stated"),
        ActionParameter("body", required: false, sensitive: true, description: "Message text"),
    ]

    @MainActor
    func run(_ arguments: ActionArguments) async throws {
        let subject = AppleScript.quoted(arguments["subject"] ?? "")
        let body = AppleScript.quoted(arguments["body"] ?? "")
        var script = """
            tell application "Mail"
                set draft to make new outgoing message with properties \
                    {subject:\(subject), content:\(body), visible:true}
            """
        if let recipient = arguments["to"], !recipient.isEmpty {
            let address = AppleScript.quoted(recipient)
            script += "\n    tell draft to make new to recipient with properties {address:\(address)}"
        }
        script += "\n    activate\nend tell"
        try AppleScript.run(script)
    }
}

/// Spotlight through `mdfind`: names first, then content matches, in the user's home.
enum Spotlight {
    static func search(_ query: String) async throws -> [URL] {
        let home = URL.homeDirectory.path
        let escaped = query.replacingOccurrences(of: "\"", with: "")
        let byName = try await CommandLineTool.run(
            "/usr/bin/mdfind", ["-onlyin", home, "kMDItemDisplayName == \"*\(escaped)*\"cd"]
        )
        let lines = byName.isEmpty
            ? try await CommandLineTool.run("/usr/bin/mdfind", ["-onlyin", home, escaped])
            : byName
        return lines.split(separator: "\n")
            .filter { !$0.contains("/Library/") && !$0.contains("/.") }
            .map { URL(filePath: String($0)) }
    }
}

/// Runs a tool without a shell (no quoting issues); stdout, or the error output on failure.
enum CommandLineTool {
    static func run(_ path: String, _ arguments: [String], timeout: Duration = .seconds(60)) async throws -> String {
        let process = Process()
        process.executableURL = URL(filePath: path)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let box = UncheckedProcess(process)
        let watchdog = DispatchWorkItem { box.process.terminate() }
        let seconds = Double(timeout.components.seconds)
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: watchdog)
        defer { watchdog.cancel() }
        let data = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let data = output.fileHandleForReading.readDataToEndOfFile()
                box.process.waitUntilExit()
                continuation.resume(returning: data)
            }
        }
        let text = (String(bytes: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            let detail = String(bytes: errors.fileHandleForReading.availableData, encoding: .utf8) ?? ""
            throw ActionError.failed(detail.isEmpty ? "\(path) exit \(process.terminationStatus)" : detail)
        }
        return text
    }
}

private final class UncheckedProcess: @unchecked Sendable {
    let process: Process

    init(_ process: Process) {
        self.process = process
    }
}
