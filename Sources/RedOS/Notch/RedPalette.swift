import SwiftUI

/// The island's colours: one red signal, orange only for warnings, the rest in greys.
enum RedPalette {
    static let signal = Color.red
    static let onSignal = Color.white
    static let warning = Color.orange
    static let text = Color.white.opacity(0.85)
    static let orb: [Color] = [.red, .orange, .pink, .red]
    static let bars: [Color] = [.orange, .red]
}

/// The one Stop button of every island, red even when its panel is not key.
struct StopButton: View {
    let action: () -> Void

    var body: some View {
        Button("Stop", systemImage: "stop.fill", action: action)
            .buttonStyle(StopButtonStyle())
    }
}

private struct StopButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StopCapsule(configuration: configuration)
    }
}

private struct StopCapsule: View {
    let configuration: ButtonStyleConfiguration
    @State private var isHovering = false

    var body: some View {
        configuration.label
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(RedPalette.onSignal)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(RedPalette.signal.opacity(opacity), in: .capsule)
            .contentShape(.capsule)
            .onHover { isHovering = $0 }
    }

    private var opacity: Double {
        configuration.isPressed ? 0.7 : isHovering ? 0.85 : 1
    }
}
