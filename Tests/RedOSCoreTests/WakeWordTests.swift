import AVFoundation
import Foundation
import Testing
@testable import RedOSWakeWord

/// The bundled "Hey Red" model against speech synthesized with `say`.
@Suite(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/say")))
struct WakeWordTests {
    private static let models = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appending(path: "Resources/WakeWord")

    @Test func detectsTheWakeWord() async throws {
        #expect(try await score("Hey Red") > 0.5)
    }

    @Test func ignoresOtherSpeech() async throws {
        #expect(try await score("Apri Safari e vai su apple.com") < 0.2)
        #expect(try await score("Hello there, how are you?") < 0.2)
    }

    /// Best score over the phrase with a second of silence around it, fed in 100 ms blocks like the microphone.
    private func score(_ phrase: String) async throws -> Float {
        let detector = try WakeWordDetector(
            model: Self.models.appending(path: "hey_red.onnx"), featureModels: Self.models
        )
        let silence = [Float](repeating: 0, count: 16000)
        let audio = silence + (try Self.speech(phrase)) + silence
        var best: Float = 0
        for start in stride(from: 0, to: audio.count, by: 1600) {
            best = max(best, try await detector.process(Array(audio[start..<min(start + 1600, audio.count)])))
        }
        return best
    }

    private static func speech(_ phrase: String) throws -> [Float] {
        let url = FileManager.default.temporaryDirectory.appending(path: "redos-wake-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let say = Process()
        say.executableURL = URL(filePath: "/usr/bin/say")
        say.arguments = ["-o", url.path, "--data-format=LEI16@16000", phrase]
        try say.run()
        say.waitUntilExit()
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 160_000))
        try file.read(into: buffer)
        let channel = try #require(buffer.floatChannelData?[0])
        return UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)).map { $0 * 32767 }
    }
}
