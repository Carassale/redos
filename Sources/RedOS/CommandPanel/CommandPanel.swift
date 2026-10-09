import AppKit
import SwiftUI

/// Borderless, non-activating panel: typing goes here while the previous app stays frontmost.
final class CommandPanel: NSPanel {
    /// Returns true when the key was handled (e.g. history navigation) and must not reach the text field.
    var onKeyDown: ((NSEvent) -> Bool)?

    init(rootView: some View) {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
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
        orderOut(nil)
    }
}
