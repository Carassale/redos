import CoreGraphics
import Foundation
import RedOSCore

struct TypeTextAction: Action {
    let id = "text.type"
    let summary = "Type text where the cursor already is, as if from the keyboard."
    let risk = RiskLevel.moderate
    let parameters = [ActionParameter("text", sensitive: true, description: "The exact text to type")]
    let requiredPermissions = [Permission.accessibility]

    @MainActor
    func run(_ arguments: ActionArguments) async throws {
        try await InputEvents.type(try arguments.string("text"))
    }
}

struct ScrollAction: Action {
    let id = "scroll"
    let summary = "Scroll the content under the pointer up, down, left or right"
        + " (go to the bottom, go back up, move sideways)."
    let risk = RiskLevel.safe
    let parameters = [
        ActionParameter("direction", .oneOf(["up", "down", "left", "right"]), description: "Scroll direction"),
        ActionParameter("amount", .integer, required: false, description: "Number of lines, only if stated"),
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
    let summary = "Move the mouse pointer to explicit numeric screen coordinates."
    let risk = RiskLevel.safe
    let parameters = [
        ActionParameter("x", .integer, description: "Horizontal screen coordinate in points"),
        ActionParameter("y", .integer, description: "Vertical screen coordinate in points"),
    ]
    let requiredPermissions = [Permission.accessibility]

    @MainActor
    func run(_ arguments: ActionArguments) async throws {
        let point = CGPoint(x: arguments.integer("x") ?? 0, y: arguments.integer("y") ?? 0)
        try InputEvents.post(.mouseMoved, at: point, button: .left)
    }
}

struct ClickAction: Action {
    let id = "mouse.click"
    let summary = "Click at the current pointer position or at explicit numeric coordinates."
        + " Not for named buttons (use ui.press)."
    let risk = RiskLevel.moderate
    let parameters = [
        ActionParameter("x", .integer, required: false, description: "Horizontal screen coordinate, only if stated"),
        ActionParameter("y", .integer, required: false, description: "Vertical screen coordinate, only if stated"),
        ActionParameter("button", .oneOf(["left", "right"]), required: false, description: "Mouse button"),
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

    static func click(at point: CGPoint) throws(ActionError) {
        try post(.mouseMoved, at: point, button: .left)
        try post(.leftMouseDown, at: point, button: .left)
        try post(.leftMouseUp, at: point, button: .left)
    }

    /// Cmd+A in the focused app.
    static func selectAll() throws(ActionError) {
        let keyA: CGKeyCode = 0
        for keyDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: keyA, keyDown: keyDown) else {
                throw creationFailed
            }
            event.flags = .maskCommand
            event.post(tap: .cghidEventTap)
        }
    }

    @MainActor
    static func type(_ text: String) async throws {
        let characters = Array(text)
        let source = CGEventSource(stateID: .combinedSessionState)
        // Chunked on Character boundaries: some apps drop long unicode payloads.
        for start in stride(from: 0, to: characters.count, by: 16) {
            var units = Array(String(characters[start..<min(start + 16, characters.count)]).utf16)
            for keyDown in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: keyDown) else {
                    throw creationFailed
                }
                event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
                event.post(tap: .cghidEventTap)
            }
            try await Task.sleep(for: .milliseconds(8))
        }
    }
}
