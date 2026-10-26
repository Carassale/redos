import AppKit
import RedOSCore
import SwiftUI
import WebKit

/// Shows a diagram large, in a resizable window.
@MainActor
final class DiagramWindowController {
    private var window: NSWindow?

    func show(_ diagram: Diagram) {
        let view = DiagramView(diagram: diagram)
        if let window {
            window.contentViewController = NSHostingController(rootView: view)
            window.title = diagram.title
        } else {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.title = diagram.title
            let hosting = NSHostingController(rootView: view)
            hosting.sizingOptions = []
            window.contentViewController = hosting
            window.setContentSize(NSSize(width: 1100, height: 760))
            window.center()
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

private struct DiagramView: View {
    let diagram: Diagram

    var body: some View {
        MermaidView(diagram: diagram)
            .toolbar {
                ToolbarItemGroup {
                    Button("Show in Finder", systemImage: "folder") {
                        NSWorkspace.shared.activateFileViewerSelecting([diagram.file])
                    }
                    Button("Open in Browser", systemImage: "safari") {
                        NSWorkspace.shared.open(diagram.file)
                    }
                }
            }
    }
}

/// The diagram inside the answer, as tall as it draws up to `maxHeight`; a click opens it large.
struct DiagramPreview: View {
    static let maxHeight = 240

    let diagram: Diagram
    let onOpen: () -> Void
    @State private var height: CGFloat = 80

    var body: some View {
        MermaidView(
            diagram: diagram, maxHeight: Self.maxHeight,
            onHeight: { height = min($0, CGFloat(Self.maxHeight)) }, onClick: onOpen
        )
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .help("Open Diagram")
    }
}

/// Mermaid, bundled with the app, draws the diagram offline; links open in the browser.
struct MermaidView: NSViewRepresentable {
    let diagram: Diagram
    var maxHeight: Int?
    var onHeight: (CGFloat) -> Void = { _ in }
    /// Set for a preview: the view only takes clicks and passes scrolling on.
    var onClick: (() -> Void)?

    private static let mermaid = Bundle.main
        .url(forResource: "mermaid.min", withExtension: "js", subdirectory: "Mermaid")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MermaidCanvas {
        let configuration = WKWebViewConfiguration()
        if let mermaid = Self.mermaid {
            configuration.userContentController.addUserScript(
                WKUserScript(source: mermaid, injectionTime: .atDocumentStart, forMainFrameOnly: true)
            )
        }
        configuration.userContentController.add(context.coordinator, name: "size")
        let view = MermaidCanvas(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        return view
    }

    func updateNSView(_ view: MermaidCanvas, context: Context) {
        context.coordinator.onHeight = onHeight
        view.onClick = onClick
        guard context.coordinator.source != diagram.source else { return }
        context.coordinator.source = diagram.source
        view.loadHTMLString(
            MermaidPage.html(diagram.source, title: diagram.title, maxHeight: maxHeight), baseURL: nil
        )
    }

    static func dismantleNSView(_ view: MermaidCanvas, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "size")
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var source: String?
        var onHeight: (CGFloat) -> Void = { _ in }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            if let height = message.body as? Double { onHeight(CGFloat(height)) }
        }

        func webView(
            _ webView: WKWebView, decidePolicyFor action: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            guard action.navigationType == .linkActivated, let url = action.request.url else { return .allow }
            if url.scheme == "https" || url.scheme == "http" { NSWorkspace.shared.open(url) }
            return .cancel
        }
    }
}

final class MermaidCanvas: WKWebView {
    var onClick: (() -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard onClick != nil else { return super.hitTest(point) }
        return super.hitTest(point) == nil ? nil : self
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        onClick != nil || super.acceptsFirstMouse(for: event)
    }

    override func mouseDown(with event: NSEvent) {
        guard let onClick else { return super.mouseDown(with: event) }
        onClick()
    }

    override func scrollWheel(with event: NSEvent) {
        guard onClick != nil else { return super.scrollWheel(with: event) }
        nextResponder?.scrollWheel(with: event)
    }

    override func resetCursorRects() {
        guard onClick != nil else { return super.resetCursorRects() }
        addCursorRect(bounds, cursor: .pointingHand)
    }
}
