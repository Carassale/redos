import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
final class HUDModel {
    var text = ""
    var isOpen = false
    var notch = NotchGeometry()
    @ObservationIgnored var onStop: () -> Void = {}
}

struct HUDView: View {
    static let size = CGSize(width: 600, height: 120)

    let model: HUDModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NotchIsland(notch: model.notch, isOpen: model.isOpen, width: 500) {
            HStack(spacing: 7) {
                Image(systemName: "record.circle.fill")
                    .foregroundStyle(RedPalette.signal)
                    .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
                Text(verbatim: "RedOS")
                    .foregroundStyle(RedPalette.text)
            }
            .font(.system(size: 12, weight: .semibold))
        } trailing: {
            StopButton(action: model.onStop)
        } content: {
            HStack(spacing: 8) {
                Text(verbatim: model.text)
                    .font(.callout)
                    .foregroundStyle(RedPalette.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .contentTransition(.opacity)
                Spacer(minLength: 8)
                Text(verbatim: "⌃⌥⎋")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .animation(.smooth(duration: 0.2), value: model.text)
        }
        .frame(width: Self.size.width, height: Self.size.height, alignment: .top)
        .ignoresSafeArea()
    }
}

/// Always-visible island in the notch while RedOS drives the Mac, with a Stop button (same as the kill switch).
@MainActor
final class HUDController {
    private let model = HUDModel()
    private var pending: Task<Void, Never>?
    private var closing: Task<Void, Never>?
    private lazy var panel: NSPanel = {
        let panel = HUDPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .notch
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let hosting = NSHostingController(rootView: HUDView(model: model))
        hosting.sizingOptions = []
        panel.contentViewController = hosting
        panel.setContentSize(HUDView.size)
        return panel
    }()

    init(onStop: @escaping @MainActor () -> Void) {
        model.onStop = onStop
    }

    /// Delayed so instant commands do not flash it.
    func show(_ text: String, after delay: Duration = .milliseconds(250)) {
        model.text = text
        if closing != nil {
            closing?.cancel()
            closing = nil
            model.isOpen = true
            return
        }
        guard !panel.isVisible, pending == nil else { return }
        pending = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            pending = nil
            if let screen = NotchGeometry.screen {
                model.notch = NotchGeometry(screen: screen)
                panel.pinToNotch(of: screen)
            }
            panel.orderFrontRegardless()
            model.isOpen = true
        }
    }

    func update(_ text: String) {
        model.text = text
    }

    func hide() {
        pending?.cancel()
        pending = nil
        guard panel.isVisible, closing == nil else { return }
        model.isOpen = false
        closing = Task { [weak self] in
            try? await Task.sleep(for: NotchMotion.closeDelay)
            guard let self, !Task.isCancelled else { return }
            closing = nil
            panel.orderOut(nil)
        }
    }
}

private final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
