import SwiftUI

struct CommandPanelView: View {
    @Bindable var model: CommandPanelModel
    let onSubmit: () -> Void
    let onCancel: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "circle.hexagongrid.fill")
                    .font(.title2)
                    .foregroundStyle(.red)
                TextField("Ask RedOS…", text: $model.text)
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
        .frame(width: 640, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .onExitCommand(perform: onCancel)
        .onAppear { isFocused = true }
        .onChange(of: model.focusRequest) { isFocused = true }
        .onChange(of: model.text) {
            if case .confirming = model.state { model.state = .idle }
        }
    }

    @ViewBuilder
    private var status: some View {
        switch model.state {
        case .idle, .working:
            EmptyView()
        case .confirming(let command):
            Label(
                "Run \(command.request.actionID)? Press Return to confirm, Esc to cancel.",
                systemImage: "exclamationmark.triangle"
            )
            .foregroundStyle(.orange)
        case .message(let text, let isError):
            Label(text, systemImage: isError ? "xmark.octagon" : "checkmark.circle")
                .foregroundStyle(isError ? .red : .secondary)
        }
    }
}
