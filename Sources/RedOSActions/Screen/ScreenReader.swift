import AppKit
import ApplicationServices
import RedOSCore

/// Typed reads of Accessibility attributes.
extension AXUIElement {
    func value(_ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    func string(_ attribute: String) -> String? {
        guard let text = value(attribute) as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func bool(_ attribute: String) -> Bool? {
        value(attribute) as? Bool
    }

    func element(_ attribute: String) -> AXUIElement? {
        guard let value = value(attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    var children: [AXUIElement] {
        (value(kAXChildrenAttribute) as? [AnyObject] ?? []).compactMap { child in
            CFGetTypeID(child) == AXUIElementGetTypeID() ? unsafeDowncast(child, to: AXUIElement.self) : nil
        }
    }

    var role: String { string(kAXRoleAttribute) ?? "" }

    var frame: CGRect? {
        guard let position = value(kAXPositionAttribute), let size = value(kAXSizeAttribute),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID()
        else { return nil }
        var origin = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(unsafeDowncast(position, to: AXValue.self), .cgPoint, &origin),
              AXValueGetValue(unsafeDowncast(size, to: AXValue.self), .cgSize, &extent)
        else { return nil }
        return CGRect(origin: origin, size: extent)
    }
}

/// An element the user or the agent can act on.
struct ScreenElement {
    let id: Int
    let kind: String
    let label: String
    let value: String?
    let element: AXUIElement
}

struct ScreenSnapshot {
    let app: String
    let window: String?
    let elements: [ScreenElement]
    let texts: [String]

    /// Numbered listing for the agent.
    var listing: String {
        var lines = ["App: \(app)" + (window.map { ", window \"\($0)\"" } ?? "")]
        lines += elements.map { element in
            "[\(element.id)] \(element.kind) \"\(element.label)\"" + (element.value.map { " = \"\($0)\"" } ?? "")
        }
        if !texts.isEmpty {
            lines.append("Text: " + texts.joined(separator: " | "))
        }
        return lines.joined(separator: "\n")
    }

    /// Plain reading for the user.
    var reading: String {
        let title = [app, window].compactMap(\.self).joined(separator: " — ")
        let body = texts.isEmpty ? elements.map(\.label) : texts
        return ([title] + body).joined(separator: "\n")
    }
}

/// Reads the frontmost app's focused window and menu bar through the Accessibility API.
@MainActor
enum ScreenReader {
    /// The latest snapshot: element numbers ("#12") refer to it.
    private(set) static var last: ScreenSnapshot?

    private static let kinds = [
        "AXButton": "button", "AXLink": "link", "AXTextField": "field", "AXTextArea": "field",
        "AXComboBox": "field", "AXCheckBox": "checkbox", "AXRadioButton": "option", "AXPopUpButton": "popup",
        "AXMenuButton": "menu button", "AXDisclosureTriangle": "disclosure", "AXSlider": "slider",
        "AXSwitch": "switch", "AXMenuItem": "menu item", "AXMenuBarItem": "menu",
    ]
    private static let textRoles: Set<String> = ["AXStaticText", "AXHeading"]

    static func snapshot() throws(ActionError) -> ScreenSnapshot {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            throw .failed(String(localized: "No app is in front."))
        }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 1)
        let window = root.element(kAXFocusedWindowAttribute) ?? root.element(kAXMainWindowAttribute)
        var builder = Builder(bounds: window?.frame)
        if let menuBar = root.element(kAXMenuBarAttribute) {
            builder.visitMenuBar(menuBar)
        }
        if let window {
            builder.visit(window, depth: 0)
        }
        let snapshot = ScreenSnapshot(
            app: app.localizedName ?? "", window: window?.string(kAXTitleAttribute),
            elements: builder.elements, texts: builder.texts
        )
        last = snapshot
        return snapshot
    }

    /// Everything readable in the frontmost window (text, link and button labels, page address), for
    /// answering questions about it.
    static func content(maxCharacters: Int = 16000) throws(ActionError) -> ScreenContent {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            throw .failed(String(localized: "No app is in front."))
        }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 2)
        let window = root.element(kAXFocusedWindowAttribute) ?? root.element(kAXMainWindowAttribute)
        var builder = Builder(bounds: nil, reading: true)
        if let window { builder.visit(window, depth: 0) }
        var text = ""
        for line in builder.texts {
            guard text.count + line.count < maxCharacters else { break }
            text += line + "\n"
        }
        return ScreenContent(
            app: app.localizedName ?? "", window: window?.string(kAXTitleAttribute),
            address: builder.webAddress?.absoluteString, text: text
        )
    }

    /// "Google Chrome — Merge request !12", for routing context.
    static func frontmost() -> String? {
        guard let app = NSWorkspace.shared.frontmostApplication, let name = app.localizedName else { return nil }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.3)
        let title = (root.element(kAXFocusedWindowAttribute) ?? root.element(kAXMainWindowAttribute))?
            .string(kAXTitleAttribute)
        return title.map { "\(name) — \($0)" } ?? name
    }

    /// "#12" picks from the latest snapshot; a name is matched on screen, then in the app's menus.
    static func find(_ target: String) throws(ActionError) -> ScreenElement {
        if target.hasPrefix("#"), let id = Int(target.dropFirst()) {
            guard let element = last?.elements.first(where: { $0.id == id }) else {
                throw .failed(String(localized: "Element \(target) is no longer on screen."))
            }
            return element
        }
        let snapshot = try snapshot()
        if let index = NameMatcher.bestMatch(for: target, in: snapshot.elements.map(\.label)) {
            return snapshot.elements[index]
        }
        let items = menuItems()
        if let index = NameMatcher.bestMatch(for: target, in: items.map(\.label)) {
            return items[index]
        }
        throw .failed(String(localized: "Nothing named “\(target)” on screen."))
    }

    /// Every item of the frontmost app's menus, opened or not (AXPress works on closed menus too).
    private static func menuItems() -> [ScreenElement] {
        guard let app = NSWorkspace.shared.frontmostApplication else { return [] }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        var items: [ScreenElement] = []
        func collect(_ element: AXUIElement, depth: Int) {
            guard depth < 6, items.count < 800 else { return }
            for child in element.children {
                if child.role == "AXMenuItem", let title = child.string(kAXTitleAttribute),
                   child.bool(kAXEnabledAttribute) != false {
                    items.append(ScreenElement(id: 0, kind: "menu item", label: title, value: nil, element: child))
                }
                collect(child, depth: depth + 1)
            }
        }
        if let menuBar = root.element(kAXMenuBarAttribute) {
            collect(menuBar, depth: 0)
        }
        return items
    }

    @MainActor
    private struct Builder {
        static let maxVisited = 8000

        let bounds: CGRect?
        /// Reading mode keeps much more text, including link and button labels, for answering questions.
        let reading: Bool
        var elements: [ScreenElement] = []
        var texts: [String] = []
        var webAddress: URL?
        private var seenTexts: Set<String> = []
        private var visited = 0
        private var maxElements: Int { reading ? 3000 : 150 }
        private var maxTexts: Int { reading ? 1500 : 80 }
        private var lineLimit: Int { reading ? 1000 : 160 }

        init(bounds: CGRect?, reading: Bool = false) {
            self.bounds = bounds
            self.reading = reading
        }

        mutating func visit(_ element: AXUIElement, depth: Int) {
            guard depth < 40, visited < Self.maxVisited, elements.count < maxElements else { return }
            visited += 1
            let role = element.role
            if role == "AXWebArea", webAddress == nil, let url = element.value("AXURL") as? URL {
                webAddress = url
            }
            if let kind = ScreenReader.kinds[role] {
                if element.bool(kAXEnabledAttribute) != false, isVisible(element) {
                    add(element, kind: kind, isField: kind == "field")
                    if reading, let label = elements.last?.label, !label.isEmpty { addText(label) }
                }
                // Text inside buttons and links is their label; menus are listed separately.
                if kind != "field" { return }
            }
            if ScreenReader.textRoles.contains(role), isVisible(element),
               let text = element.string(kAXValueAttribute) ?? element.string(kAXTitleAttribute) {
                addText(text)
            }
            for child in element.children {
                visit(child, depth: depth + 1)
            }
        }

        /// Top-level menus (without the Apple menu), plus the items of the menu that is open.
        mutating func visitMenuBar(_ menuBar: AXUIElement) {
            for item in menuBar.children.dropFirst() where item.role == "AXMenuBarItem" {
                guard let title = item.string(kAXTitleAttribute) else { continue }
                append(item, kind: "menu", label: title, value: nil)
                guard item.bool(kAXSelectedAttribute) == true, let menu = item.children.first else { continue }
                let entries = menu.children.filter {
                    $0.role == "AXMenuItem" && $0.bool(kAXEnabledAttribute) != false
                }
                for entry in entries {
                    if let title = entry.string(kAXTitleAttribute) {
                        append(entry, kind: "menu item", label: title, value: nil)
                    }
                }
            }
        }

        private func isVisible(_ element: AXUIElement) -> Bool {
            guard let frame = element.frame else { return true }
            guard frame.width > 0, frame.height > 0 else { return false }
            return bounds.map { $0.intersects(frame) } ?? true
        }

        private mutating func add(_ element: AXUIElement, kind: String, isField: Bool) {
            let value = isField ? element.string(kAXValueAttribute).map { String($0.prefix(80)) } : nil
            let label = element.string(kAXTitleAttribute)
                ?? element.string(kAXDescriptionAttribute)
                ?? (isField ? element.string(kAXPlaceholderValueAttribute) : nil)
                ?? element.string(kAXHelpAttribute)
                ?? (isField ? nil : innerText(of: element, depth: 0))
            guard let label = label ?? (isField ? "" : nil) else { return }
            append(element, kind: kind, label: String(label.prefix(80)), value: value)
        }

        private mutating func append(_ element: AXUIElement, kind: String, label: String, value: String?) {
            guard elements.count < maxElements else { return }
            elements.append(
                ScreenElement(id: elements.count + 1, kind: kind, label: label, value: value, element: element)
            )
        }

        private mutating func addText(_ text: String) {
            let line = String(text.replacingOccurrences(of: "\n", with: " ").prefix(lineLimit))
            guard texts.count < maxTexts, seenTexts.insert(line).inserted else { return }
            texts.append(line)
        }

        /// Web links and buttons keep their label in child text elements.
        private func innerText(of element: AXUIElement, depth: Int) -> String? {
            guard depth < 4 else { return nil }
            let parts = element.children.compactMap { child -> String? in
                if ScreenReader.textRoles.contains(child.role) || child.role == "AXImage" {
                    return child.string(kAXValueAttribute) ?? child.string(kAXTitleAttribute)
                        ?? child.string(kAXDescriptionAttribute)
                }
                return innerText(of: child, depth: depth + 1)
            }
            let text = parts.joined(separator: " ")
            return text.isEmpty ? nil : text
        }
    }
}
