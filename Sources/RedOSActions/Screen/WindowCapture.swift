import AppKit
import RedOSCore
import ScreenCaptureKit

/// The frontmost app's front window as a JPEG for models that can see (needs Screen Recording; never asks).
enum WindowCapture {
    /// Longest side of the image: enough to read most text, ~1k image tokens.
    static let maxSide = 1280.0

    @MainActor
    static func frontmost() async -> Screenshot? {
        guard CGPreflightScreenCaptureAccess(), let app = NSWorkspace.shared.frontmostApplication else { return nil }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            // Windows come front to back; layer 0 skips menus, panels and the menu bar.
            guard let window = content.windows.first(where: {
                $0.owningApplication?.processID == app.processIdentifier && $0.windowLayer == 0
                    && $0.frame.width > 40 && $0.frame.height > 40
            }) else { return nil }
            let scale = min(1, maxSide / max(window.frame.width, window.frame.height))
            let configuration = SCStreamConfiguration()
            configuration.width = Int(window.frame.width * scale)
            configuration.height = Int(window.frame.height * scale)
            configuration.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: configuration
            )
            guard let jpeg = NSBitmapImageRep(cgImage: image)
                .representation(using: .jpeg, properties: [.compressionFactor: 0.7])
            else { return nil }
            return Screenshot(jpeg: jpeg, width: image.width, height: image.height, frame: window.frame)
        } catch {
            return nil
        }
    }
}
