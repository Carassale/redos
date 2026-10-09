import ApplicationServices
import Foundation
import RedOSCore

struct PressElementAction: Action {
    let id = "ui.press"
    let summary = "Press, click, open or select an on-screen element by its name or label: a button, link, tab,"
        + " checkbox, menu or menu item (e.g. the Save button, the File menu)."
    let risk = RiskLevel.moderate
    let parameters = [
        ActionParameter("target", description: "Only the element's visible name, e.g. Save or File")
    ]
    let requiredPermissions = [Permission.accessibility]

    @MainActor
    func run(_ arguments: ActionArguments) async throws {
        let target = try ScreenReader.find(try arguments.target())
        if AXUIElementPerformAction(target.element, kAXPressAction as CFString) == .success { return }
        // Some web and custom controls ignore AXPress: click their center instead.
        guard let frame = target.element.frame else {
            throw ActionError.failed(String(localized: "Could not press “\(target.label)”."))
        }
        try InputEvents.click(at: CGPoint(x: frame.midX, y: frame.midY))
    }
}

struct FillFieldAction: Action {
    let id = "ui.fill"
    let summary = "Write text into a text field chosen by its name or label (e.g. the Email field),"
        + " replacing its content. Not for the field where the cursor already is."
    let risk = RiskLevel.moderate
    let parameters = [
        ActionParameter("target", description: "Only the field's visible name or placeholder, e.g. Email"),
        ActionParameter("text", sensitive: true, description: "The exact text to write"),
    ]
    let requiredPermissions = [Permission.accessibility]

    @MainActor
    func run(_ arguments: ActionArguments) async throws {
        let target = try ScreenReader.find(try arguments.target())
        let text = try arguments.string("text")
        // Typing (not setting AXValue) so web forms see real input events.
        if AXUIElementSetAttributeValue(target.element, kAXFocusedAttribute as CFString, kCFBooleanTrue) != .success {
            guard let frame = target.element.frame else {
                throw ActionError.failed(String(localized: "Could not focus “\(target.label)”."))
            }
            try InputEvents.click(at: CGPoint(x: frame.midX, y: frame.midY))
        }
        try await Task.sleep(for: .milliseconds(100))
        try InputEvents.selectAll()
        try await InputEvents.type(text)
    }
}

struct ReadScreenAction: ReportingAction {
    let id = "ui.read"
    let summary = "Read out the text visible in the frontmost window, verbatim (no summaries)."
    let risk = RiskLevel.safe
    let requiredPermissions = [Permission.accessibility]

    @MainActor
    func report(_ arguments: ActionArguments) async throws -> String {
        try ScreenReader.snapshot().reading
    }
}

/// The agent's eyes: the frontmost app's numbered elements and text.
public struct AccessibilityObserver: ScreenObserving {
    public init() {}

    @MainActor
    public func observe() throws -> String {
        guard AXIsProcessTrusted() else { throw ActionError.permissionMissing(.accessibility) }
        return try ScreenReader.snapshot().listing
    }
}

extension ActionArguments {
    /// "#12" as is; spoken names without role words ("Continue button" -> "Continue").
    fileprivate func target() throws(ActionError) -> String {
        let target = try string("target")
        return target.hasPrefix("#") ? target : UITarget.clean(target) ?? target
    }
}
