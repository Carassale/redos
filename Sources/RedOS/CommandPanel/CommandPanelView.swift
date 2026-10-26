import RedOSCore
import SwiftUI

/// The assistant as an island grown out of the notch: RedOS's orb and state beside the camera, the request and
/// its result below.
struct CommandPanelView: View {
    /// The panel never resizes: the island grows inside a fixed transparent window hanging from the notch.
    static let size = CGSize(width: 720, height: 540)
    private static let islandWidth: CGFloat = 640

    @Bindable var model: CommandPanelModel
    let onSubmit: () -> Void
    let onCancel: () -> Void
    let onOpenDiagram: (Diagram) -> Void
    let onReport: () -> Void
    @FocusState private var isFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NotchIsland(notch: model.notch, isOpen: model.isOpen, width: Self.islandWidth) {
            HStack(spacing: 8) {
                RedOrb(mode: mode, level: model.level)
                Text(verbatim: modeTitle)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(RedPalette.text)
                    .lineLimit(1)
                    .contentTransition(.opacity)
            }
        } trailing: {
            trailingWing
                .font(.system(size: 13, weight: .semibold))
        } content: {
            card
        }
        .animation(.smooth(duration: 0.3), value: model.state)
        .animation(.smooth(duration: 0.2), value: mode)
        .frame(width: Self.size.width, height: Self.size.height, alignment: .top)
        .ignoresSafeArea()
        .onExitCommand(perform: onCancel)
        .onChange(of: model.focusRequest) { isFocused = true }
        .onChange(of: model.text) {
            switch model.state {
            case .confirming, .confirmingPlan: model.state = .idle
            default: break
            }
        }
    }

    private var mode: RedOrb.Mode {
        if model.state == .listening { return .listening }
        if model.isSpeaking { return .speaking }
        if model.state == .working { return .thinking }
        return model.isFollowingUp ? .listening : .idle
    }

    private var modeTitle: String {
        switch mode {
        case .listening: String(localized: "Listening…")
        case .thinking: String(localized: "Thinking…")
        case .speaking: String(localized: "Speaking…")
        case .idle: "RedOS"
        }
    }

    @ViewBuilder
    private var trailingWing: some View {
        switch mode {
        case .listening:
            LevelBars(level: model.level)
        case .speaking:
            LevelBars()
        case .thinking:
            if let symbol = model.activity?.symbol {
                Image(systemName: symbol)
                    .foregroundStyle(.secondary)
                    .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
                    .contentTransition(.symbolEffect(.replace))
            }
        case .idle:
            switch model.state {
            case .message(_, let isError):
                Image(systemName: isError ? "xmark.octagon.fill" : "checkmark.circle.fill")
                    .foregroundStyle(isError ? AnyShapeStyle(RedPalette.signal) : AnyShapeStyle(.secondary))
            case .confirming, .confirmingPlan:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(RedPalette.warning)
            case .idle, .listening, .working, .answer: EmptyView()
            }
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField(model.state == .listening ? "Listening…" : "Ask RedOS…", text: $model.text)
                .textFieldStyle(.plain)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.white)
                .focused($isFocused)
                .onSubmit(onSubmit)
            status
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // The card appears each time the island opens.
        .onAppear { isFocused = true }
    }

    @ViewBuilder
    private var status: some View {
        switch model.state {
        case .working:
            let activity = model.activity
            Label {
                Text(verbatim: activity?.title ?? String(localized: "Working…")).lineLimit(1)
            } icon: {
                Image(systemName: activity?.symbol ?? "ellipsis")
                    .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .contentTransition(.opacity)
            .animation(.easeInOut(duration: 0.2), value: activity)
        case .idle, .listening:
            EmptyView()
        case .confirming(let command):
            Label(
                "Do you want to \(Self.title(of: command.request.actionID))? Press Return to confirm, Esc to cancel.",
                systemImage: "exclamationmark.triangle"
            )
            .foregroundStyle(RedPalette.warning)
        case .confirmingPlan(let plan):
            VStack(alignment: .leading, spacing: 6) {
                Label("Run this plan? Press Return to confirm, Esc to cancel.", systemImage: "list.number")
                    .foregroundStyle(RedPalette.warning)
                ForEach(Array(plan.steps.enumerated()), id: \.offset) { index, step in
                    Text(verbatim: "\(index + 1). \(Self.describe(step))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        case .message(let text, let isError):
            HStack(alignment: .firstTextBaseline) {
                Label(text, systemImage: isError ? "xmark.octagon" : "checkmark.circle")
                    .foregroundStyle(isError ? AnyShapeStyle(RedPalette.signal) : AnyShapeStyle(.secondary))
                if isError {
                    Spacer()
                    Button("Report…", action: onReport)
                        .controlSize(.small)
                        .help("Send this error to the developer as a GitHub issue you can review first.")
                }
            }
        case .answer(let answer):
            // As tall as the answer up to 340 points, then it scrolls (ViewThatFits made the island take the
            // whole window height and pushed the answer out of it).
            ScrollView { AnswerView(answer: answer, onOpenDiagram: onOpenDiagram) }
                .frame(maxHeight: 340)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private static func describe(_ step: ActionRequest) -> String {
        let title = title(of: step.actionID)
        let sentence = title.prefix(1).uppercased() + title.dropFirst()
        let arguments = step.arguments.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }
        return arguments.isEmpty ? sentence : "\(sentence) (\(arguments.joined(separator: ", ")))"
    }

    /// What the user reads instead of the action's id, to follow "Do you want to".
    private static func title(of actionID: String) -> String {
        titles[actionID].map { String(localized: $0) } ?? String(localized: "run \(actionID)")
    }

    private static let titles: [String: String.LocalizationValue] = [
        "app.open": "open an app",
        "url.open": "open a link",
        "app.quit": "quit an app",
        "calendar.agenda": "read the calendar",
        "reminder.add": "add a reminder",
        "text.type": "type text",
        "scroll": "scroll",
        "mouse.move": "move the pointer",
        "mouse.click": "click",
        "ui.press": "press a button on screen",
        "ui.fill": "fill in a field on screen",
        "ui.read": "read the screen",
        "shell.run": "run a Terminal command",
        "volume.set": "change the volume",
        "brightness.set": "change the brightness",
        "media.control": "control playback",
        "appearance.set": "change the appearance",
        "screen.lock": "lock the screen",
        "shortcut.run": "run a shortcut",
        "window.arrange": "arrange the windows",
        "file.find": "find a file",
        "file.open": "open a file",
        "mail.draft": "draft an email",
    ]
}
