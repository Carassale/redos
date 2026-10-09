import AppKit
import RedOSCore
import SwiftUI
import WebKit

/// Shows generated diagrams (self-contained HTML/SVG) in a resizable window.
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
        DiagramWebView(file: diagram.file)
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

/// No JavaScript; links open in the default browser instead of navigating away.
private struct DiagramWebView: NSViewRepresentable {
    let file: URL

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        guard webView.url != file else { return }
        webView.loadFileURL(file, allowingReadAccessTo: file.deletingLastPathComponent())
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        func webView(
            _ webView: WKWebView, decidePolicyFor action: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            guard action.navigationType == .linkActivated, let url = action.request.url else { return .allow }
            if url.scheme == "https" || url.scheme == "http" { NSWorkspace.shared.open(url) }
            return .cancel
        }
    }
}
