import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
final class HUDModel {
    var text = ""
    @ObservationIgnored var onStop: () -> Void = {}
}

struct HUDView: View {
    let model: HUDModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "record.circle.fill")
                .foregroundStyle(.red)
                .symbolEffect(.pulse, options: .repeating)
            Text(verbatim: model.text)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Button("Stop", action: model.onStop)
                .controlSize(.small)
            Text(verbatim: "⌃⌥⎋")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(width: 440)
        .glassEffect(.regular, in: .capsule)
    }
}

/// Always-visible indicator while RedOS drives the Mac, with a Stop button (same as the kill switch).
@MainActor
final class HUDController {
    private let model = HUDModel()
    private var pending: Task<Void, Never>?
    private lazy var panel: NSPanel = {
        let panel = HUDPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let hosting = NSHostingController(rootView: HUDView(model: model))
        hosting.sizingOptions = [.preferredContentSize]
        panel.contentViewController = hosting
        return panel
    }()

    init(onStop: @escaping @MainActor () -> Void) {
        model.onStop = onStop
    }

    /// Delayed so instant commands do not flash it.
    func show(_ text: String, after delay: Duration = .milliseconds(250)) {
        model.text = text
        guard !panel.isVisible, pending == nil else { return }
        pending = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            pending = nil
            position()
            panel.orderFrontRegardless()
        }
    }

    func update(_ text: String) {
        model.text = text
    }

    func hide() {
        pending?.cancel()
        pending = nil
        panel.orderOut(nil)
    }

    /// Top right, under the menu bar: away from most content the agent clicks.
    private func position() {
        guard let screen = NSScreen.main else { return }
        let size = panel.contentViewController?.preferredContentSize ?? NSSize(width: 440, height: 40)
        let frame = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: frame.maxX - size.width - 16, y: frame.maxY - size.height - 12))
    }
}

private final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
