import AppKit
import SwiftUI

/// Borderless, non-activating panel hanging from the notch: typing goes here while the previous app stays frontmost.
final class CommandPanel: NSPanel {
    /// Returns true when the key was handled (e.g. history navigation) and must not reach the text field.
    var onKeyDown: ((NSEvent) -> Bool)?
    /// Clicking elsewhere: the island shrinks back into the notch.
    var onResignKey: (() -> Void)?

    init(rootView: some View) {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .notch
        backgroundColor = .clear
        isOpaque = false
        // The island draws its own shadow: the window one would not follow its shape as it grows.
        hasShadow = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        let hosting = NSHostingController(rootView: rootView)
        // Fixed size: letting SwiftUI resize the window fed a layout loop that overflowed the stack.
        hosting.sizingOptions = []
        contentViewController = hosting
        setContentSize(CommandPanelView.size)
    }

    override var canBecomeKey: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, onKeyDown?(event) == true { return }
        super.sendEvent(event)
    }

    override func resignKey() {
        super.resignKey()
        if let onResignKey {
            onResignKey()
        } else {
            orderOut(nil)
        }
    }
}
