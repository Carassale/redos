import RedOSCore
import SwiftUI

struct CommandPanelView: View {
    /// The panel never resizes: the card grows inside a fixed transparent window.
    static let size = CGSize(width: 640, height: 460)

    @Bindable var model: CommandPanelModel
    let onSubmit: () -> Void
    let onCancel: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        card
            .frame(width: Self.size.width, height: Self.size.height, alignment: .top)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                if model.state == .listening {
                    Image(systemName: "waveform.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.red)
                        .symbolEffect(.variableColor.iterative, options: .repeating)
                } else {
                    Image(systemName: "circle.hexagongrid.fill")
                        .font(.title2)
                        .foregroundStyle(.red)
                }
                TextField(model.state == .listening ? "Listening…" : "Ask RedOS…", text: $model.text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 22))
                    .focused($isFocused)
                    .onSubmit(onSubmit)
                if model.state == .working {
                    ProgressView().controlSize(.small)
                }
            }
            status
        }
        .padding(18)
        .frame(width: Self.size.width, alignment: .leading)
        // Plain material: .glassEffect and a self-sizing window both crashed with layout recursion (macOS 26).
        .background(.regularMaterial, in: .rect(cornerRadius: 22))
        .onExitCommand(perform: onCancel)
        .onAppear { isFocused = true }
        .onChange(of: model.focusRequest) { isFocused = true }
        .onChange(of: model.text) {
            switch model.state {
            case .confirming, .confirmingPlan: model.state = .idle
            default: break
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        switch model.state {
        case .working:
            if let progress = model.progress {
                Text(verbatim: progress).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
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
            Label(text, systemImage: isError ? "xmark.octagon" : "checkmark.circle")
                .foregroundStyle(isError ? .red : .secondary)
        case .answer(let text):
            Label {
                // Long answers scroll inside the fixed-size panel.
                ViewThatFits(in: .vertical) {
                    answer(text)
                    ScrollView { answer(text) }.frame(height: 320)
                }
            } icon: {
                Image(systemName: "sparkles").foregroundStyle(.red)
            }
        }
    }

    private func answer(_ text: String) -> some View {
        Text(verbatim: text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static func describe(_ step: ActionRequest) -> String {
        let arguments = step.arguments.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }
        return arguments.isEmpty ? step.actionID : "\(step.actionID)  \(arguments.joined(separator: ", "))"
    }
}
