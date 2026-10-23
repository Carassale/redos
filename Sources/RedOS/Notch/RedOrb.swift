import SwiftUI

/// RedOS's presence in the notch: breathes when idle, follows the voice, spins while thinking, pulses while talking.
struct RedOrb: View {
    enum Mode: Equatable {
        case idle, listening, thinking, speaking
    }

    let mode: Mode
    var level: Float = 0
    var size: CGFloat = 18

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            Circle()
                .fill(AngularGradient(
                    colors: [.red, .orange, .pink, .red],
                    center: .center,
                    angle: .degrees(time * (mode == .thinking ? 320 : 40))
                ))
                .overlay(Circle().fill(RadialGradient(
                    colors: [.white.opacity(0.6), .clear], center: UnitPoint(x: 0.32, y: 0.28),
                    startRadius: 0, endRadius: size * 0.45
                )))
                .scaleEffect(scale(at: time))
                .shadow(color: .red.opacity(0.85), radius: glow(at: time))
                .animation(.easeOut(duration: 0.12), value: level)
        }
        .frame(width: size, height: size)
    }

    private func scale(at time: Double) -> CGFloat {
        switch mode {
        case .idle: 0.92 + 0.05 * sin(time * 2)
        case .listening: 0.8 + 0.45 * CGFloat(level)
        case .thinking: 0.9 + 0.04 * sin(time * 5)
        case .speaking: 0.9 + 0.14 * abs(sin(time * 7))
        }
    }

    private func glow(at time: Double) -> CGFloat {
        switch mode {
        case .idle: 2
        case .listening: 3 + 9 * CGFloat(level)
        case .thinking: 5
        case .speaking: 3 + 5 * abs(sin(time * 7))
        }
    }
}

/// Five bars: the microphone level when `level` is set, a talking rhythm otherwise.
struct LevelBars: View {
    var level: Float?

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2.5) {
                ForEach(0..<5, id: \.self) { index in
                    Capsule()
                        .fill(LinearGradient(colors: [.orange, .red], startPoint: .top, endPoint: .bottom))
                        .frame(width: 3, height: 3 + 13 * height(index, at: time))
                }
            }
            .animation(.easeOut(duration: 0.12), value: level)
        }
        .frame(height: 16)
    }

    private func height(_ index: Int, at time: Double) -> CGFloat {
        let wave = 0.5 + 0.5 * sin(time * 8 + Double(index) * 1.4)
        guard let level else { return 0.25 + 0.65 * wave }
        let envelope = [0.55, 0.8, 1, 0.8, 0.55][index]
        return CGFloat(level) * envelope * (0.7 + 0.3 * wave)
    }
}
