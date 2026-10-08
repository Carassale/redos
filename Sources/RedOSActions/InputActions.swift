import CoreGraphics
import Foundation
import RedOSCore

struct TypeTextAction: Action {
    let id = "text.type"
    let summary = "Type text into the focused application as if from the keyboard."
    let risk = RiskLevel.moderate
    let parameters = [ActionParameter("text", sensitive: true)]
    let requiredPermissions = [Permission.accessibility]

    @MainActor
    func run(_ arguments: ActionArguments) async throws {
        let characters = Array(try arguments.string("text"))
        let source = CGEventSource(stateID: .combinedSessionState)
        // Chunked on Character boundaries: some apps drop long unicode payloads.
        for start in stride(from: 0, to: characters.count, by: 16) {
            var units = Array(String(characters[start..<min(start + 16, characters.count)]).utf16)
            for keyDown in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: keyDown) else {
                    throw InputEvents.creationFailed
                }
                event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
                event.post(tap: .cghidEventTap)
            }
            try await Task.sleep(for: .milliseconds(8))
        }
    }
}

struct ScrollAction: Action {
    let id = "scroll"
    let summary = "Scroll the content under the mouse pointer by a number of lines."
    let risk = RiskLevel.safe
    let parameters = [
        ActionParameter("direction", .oneOf(["up", "down", "left", "right"])),
        ActionParameter("amount", .integer, required: false),
    ]
    let requiredPermissions = [Permission.accessibility]

    @MainActor
    func run(_ arguments: ActionArguments) async throws {
        let lines = Int32(min(max(arguments.integer("amount") ?? 5, 1), 100))
        let (vertical, horizontal): (Int32, Int32) = switch arguments["direction"] {
        case "up": (lines, 0)
        case "left": (0, lines)
        case "right": (0, -lines)
        default: (-lines, 0)
        }
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil, units: .line, wheelCount: 2,
            wheel1: vertical, wheel2: horizontal, wheel3: 0
        ) else { throw InputEvents.creationFailed }
        event.post(tap: .cghidEventTap)
    }
}

struct MoveMouseAction: Action {
    let id = "mouse.move"
    let summary = "Move the mouse pointer to absolute screen coordinates (points, origin top-left)."
    let risk = RiskLevel.safe
    let parameters = [ActionParameter("x", .integer), ActionParameter("y", .integer)]
    let requiredPermissions = [Permission.accessibility]

    @MainActor
    func run(_ arguments: ActionArguments) async throws {
        let point = CGPoint(x: arguments.integer("x") ?? 0, y: arguments.integer("y") ?? 0)
        try InputEvents.post(.mouseMoved, at: point, button: .left)
    }
}

struct ClickAction: Action {
    let id = "mouse.click"
    let summary = "Click at the given screen coordinates, or at the current pointer position if omitted."
    let risk = RiskLevel.moderate
    let parameters = [
        ActionParameter("x", .integer, required: false),
        ActionParameter("y", .integer, required: false),
        ActionParameter("button", .oneOf(["left", "right"]), required: false),
    ]
    let requiredPermissions = [Permission.accessibility]

    @MainActor
    func run(_ arguments: ActionArguments) async throws {
        var point = CGEvent(source: nil)?.location ?? .zero
        if let x = arguments.integer("x"), let y = arguments.integer("y") {
            point = CGPoint(x: x, y: y)
            try InputEvents.post(.mouseMoved, at: point, button: .left)
        }
        let isRight = arguments["button"] == "right"
        let button: CGMouseButton = isRight ? .right : .left
        try InputEvents.post(isRight ? .rightMouseDown : .leftMouseDown, at: point, button: button)
        try InputEvents.post(isRight ? .rightMouseUp : .leftMouseUp, at: point, button: button)
    }
}

enum InputEvents {
    static var creationFailed: ActionError {
        .failed(String(localized: "Could not create input event."))
    }

    static func post(_ type: CGEventType, at point: CGPoint, button: CGMouseButton) throws(ActionError) {
        guard let event = CGEvent(
            mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button
        ) else { throw creationFailed }
        event.post(tap: .cghidEventTap)
    }
}
