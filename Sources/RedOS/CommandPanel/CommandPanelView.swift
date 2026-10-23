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

    var body: some View {
        NotchIsland(notch: model.notch, isOpen: model.isOpen, width: Self.islandWidth) {
            HStack(spacing: 8) {
                RedOrb(mode: mode, level: model.level)
                Text(verbatim: modeTitle)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
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
            Image(systemName: model.activity?.symbol ?? "sparkles")
                .foregroundStyle(.orange)
                .symbolEffect(.pulse, options: .repeating)
                .contentTransition(.symbolEffect(.replace))
        case .idle:
            switch model.state {
            case .answer: Image(systemName: "sparkles").foregroundStyle(.red)
            case .message(_, let isError):
                Image(systemName: isError ? "xmark.octagon.fill" : "checkmark.circle.fill")
                    .foregroundStyle(isError ? .red : .green)
            case .confirming, .confirmingPlan:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            case .idle, .listening, .working: EmptyView()
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
                Image(systemName: activity?.symbol ?? "sparkles")
                    .symbolEffect(.pulse, options: .repeating)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .contentTransition(.opacity)
            .animation(.easeInOut(duration: 0.2), value: activity)
        case .idle, .listening:
            EmptyView()
        case .confirming(let command):
            Label(
                "Run \(command.request.actionID)? Press Return to confirm, Esc to cancel.",
                systemImage: "exclamationmark.triangle"
            )
            .foregroundStyle(.orange)
        case .confirmingPlan(let plan):
            VStack(alignment: .leading, spacing: 6) {
                Label("Run this plan? Press Return to confirm, Esc to cancel.", systemImage: "list.number")
                    .foregroundStyle(.orange)
                ForEach(Array(plan.steps.enumerated()), id: \.offset) { index, step in
                    Text(verbatim: "\(index + 1). \(Self.describe(step))")
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
        case .message(let text, let isError):
            HStack(alignment: .firstTextBaseline) {
                Label(text, systemImage: isError ? "xmark.octagon" : "checkmark.circle")
                    .foregroundStyle(isError ? .red : .secondary)
                if isError {
                    Spacer()
                    Button("Report…", action: onReport)
                        .controlSize(.small)
                        .help("Send this error to the developer as a GitHub issue you can review first.")
                }
            }
        case .answer(let answer):
            Label {
                // Long answers scroll inside the fixed-size panel.
                ViewThatFits(in: .vertical) {
                    AnswerView(answer: answer, onOpenDiagram: onOpenDiagram)
                    ScrollView { AnswerView(answer: answer, onOpenDiagram: onOpenDiagram) }.frame(height: 340)
                }
            } icon: {
                Image(systemName: "sparkles").foregroundStyle(.red)
            }
        }
    }

    private static func describe(_ step: ActionRequest) -> String {
        let arguments = step.arguments.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }
        return arguments.isEmpty ? step.actionID : "\(step.actionID)  \(arguments.joined(separator: ", "))"
    }
}
