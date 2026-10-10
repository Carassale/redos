import AppKit
import RedOSCore

struct VolumeAction: Action {
    let id = "volume.set"
    let summary = "Change the sound volume: set a level from 0 to 100, turn it up or down, mute or unmute."
    let risk = RiskLevel.safe
    let parameters = [
        ActionParameter("change", .oneOf(["up", "down", "mute", "unmute"]), required: false,
                        description: "Relative change, only if no level is given"),
        ActionParameter("level", .integer, required: false, description: "Volume from 0 to 100, only if stated"),
    ]

    @MainActor
    func run(_ arguments: ActionArguments) async throws {
        let script = if let level = arguments.integer("level") {
            "set volume output volume \(min(max(level, 0), 100)) without output muted"
        } else {
            switch arguments["change"] {
            case "mute": "set volume with output muted"
            case "unmute": "set volume without output muted"
            case "down": "set volume output volume ((output volume of (get volume settings)) - 15)"
            default: "set volume output volume ((output volume of (get volume settings)) + 15) without output muted"
            }
        }
        try AppleScript.run(script)
    }
}

struct BrightnessAction: Action {
    let id = "brightness.set"
    let summary = "Make the display brighter or darker."
    let risk = RiskLevel.safe
    let parameters = [
        ActionParameter("direction", .oneOf(["up", "down"]), description: "Brighter (up) or darker (down)"),
        ActionParameter("steps", .integer, required: false, description: "Number of steps (1-16), only if stated"),
    ]
    let requiredPermissions = [Permission.accessibility]

    @MainActor
    func run(_ arguments: ActionArguments) async throws {
        let key: MediaKey = arguments["direction"] == "down" ? .brightnessDown : .brightnessUp
        for _ in 0..<min(max(arguments.integer("steps") ?? 3, 1), 16) {
            key.press()
        }
    }
}

struct MediaAction: Action {
    let id = "media.control"
    let summary = "Control the music or video playing in any app: play, pause, next or previous track."
    let risk = RiskLevel.safe
    let parameters = [
        ActionParameter(
            "command", .oneOf(["play", "pause", "next", "previous"]),
            description: "play or pause (resume / stop the music), next or previous track"
        ),
    ]
    let requiredPermissions = [Permission.accessibility]

    @MainActor
    func run(_ arguments: ActionArguments) async throws {
        switch arguments["command"] {
        case "next": MediaKey.next.press()
        case "previous": MediaKey.previous.press()
        // The media key toggles: play and pause are the same key.
        default: MediaKey.playPause.press()
        }
    }
}

struct AppearanceAction: Action {
    let id = "appearance.set"
    let summary = "Switch macOS between dark mode and light mode."
    let risk = RiskLevel.safe
    let parameters = [ActionParameter("mode", .oneOf(["dark", "light", "toggle"]), description: "Appearance")]

    @MainActor
    func run(_ arguments: ActionArguments) async throws {
        let value = switch arguments["mode"] {
        case "dark": "true"
        case "light": "false"
        default: "not dark mode"
        }
        try AppleScript.run(
            "tell application \"System Events\" to tell appearance preferences to set dark mode to \(value)"
        )
    }
}

struct LockScreenAction: Action {
    let id = "screen.lock"
    let summary = "Lock the Mac: show the lock screen that asks for the password."
    let risk = RiskLevel.moderate
    let requiredPermissions = [Permission.accessibility]

    @MainActor
    func run(_ arguments: ActionArguments) async throws {
        // ⌃⌘Q, the system shortcut for Lock Screen.
        try InputEvents.press(keyCode: 0x0C, flags: [.maskControl, .maskCommand])
    }
}

/// Media and brightness keys, posted like the keyboard's own (system-defined events).
enum MediaKey: Int32 {
    case brightnessUp = 2
    case brightnessDown = 3
    case playPause = 16
    case next = 17
    case previous = 18

    @MainActor
    func press() {
        for isDown in [true, false] {
            let flags = NSEvent.ModifierFlags(rawValue: isDown ? 0xA00 : 0xB00)
            let data = Int((rawValue << 16) | ((isDown ? 0xA : 0xB) << 8))
            NSEvent.otherEvent(
                with: .systemDefined, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: 0, context: nil, subtype: 8, data1: data, data2: -1
            )?.cgEvent?.post(tap: .cghidEventTap)
        }
    }
}

enum AppleScript {
    @MainActor
    static func run(_ source: String) throws {
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            let message = error[NSAppleScript.errorMessage] as? String ?? "AppleScript error"
            throw ActionError.failed(message)
        }
    }

    @MainActor
    static func value(_ source: String) throws -> String {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            throw ActionError.failed(error[NSAppleScript.errorMessage] as? String ?? "AppleScript error")
        }
        return result?.stringValue ?? ""
    }

    /// A string literal for AppleScript source.
    static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
